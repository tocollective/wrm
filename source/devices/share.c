// 64-bit file offsets on 32-bit hosts too; fseeko, fileno, lstat, fsync,
// ftruncate and realpath under strict C99
#define _FILE_OFFSET_BITS 64
#ifndef _WIN32
#define _DEFAULT_SOURCE
#endif

#include "devices/share.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

#ifdef _WIN32
#include <direct.h>
#include <io.h>
#include <windows.h>
typedef struct _stat64 share_stat_t;
#define share_stat _stat64
#define share_lstat _stat64 // no symbolic links to tell apart
#define share_fstat _fstat64
#define share_fseek _fseeki64
#define share_open_fd _open
#define share_close _close
#define share_fdopen _fdopen
#define share_mkdir(path) _mkdir(path)
#define share_rmdir _rmdir
#define share_unlink _unlink
#define SHARE_O_BINARY _O_BINARY
#ifndef S_ISDIR
#define S_ISDIR(m) (((m) & _S_IFMT) == _S_IFDIR)
#endif
#ifndef S_ISREG
#define S_ISREG(m) (((m) & _S_IFMT) == _S_IFREG)
#endif
#else
#include <dirent.h>
#include <unistd.h>
typedef struct stat share_stat_t;
#define share_stat stat
#define share_lstat lstat
#define share_fstat fstat
#define share_fseek fseeko
#define share_open_fd open
#define share_close close
#define share_fdopen fdopen
#define share_mkdir(path) mkdir(path, 0777)
#define share_rmdir rmdir
#define share_unlink unlink
#define SHARE_O_BINARY 0
#endif

// ---- the host's side ----------------------------------------------------------

// An open directory
typedef struct share_dir {
	char* path; // its host path, to stat the entries
#ifdef _WIN32
	HANDLE find;
	WIN32_FIND_DATAA data;
	bool pending; // data holds an entry not given out yet
#else
	DIR* dir;
#endif
} share_dir_t;

static char* share_strdup(const char* text) {
	const size_t length = strlen(text) + 1;
	char* copy = malloc(length);
	if (!copy) error("Failed to allocate the shared folder!");
	memcpy(copy, text, length);
	return copy;
}

// The host error as a register value
static uint32_t share_errno(const int number) {
	switch (number) {
		case ENOENT:
			return SHARE_ERROR_NOT_FOUND;
		case EEXIST:
			return SHARE_ERROR_EXISTS;
		case EISDIR:
		case ENOTDIR:
			return SHARE_ERROR_TYPE;
		case ENOTEMPTY:
			return SHARE_ERROR_NOT_EMPTY;
	}
	return SHARE_ERROR_HOST;
}

// NULL with errno set if it can't be opened
static share_dir_t* share_dir_open(const char* path) {
	share_dir_t* dir = calloc(1, sizeof(share_dir_t));
	if (!dir) error("Failed to allocate the shared folder!");
	dir->path = share_strdup(path);
#ifdef _WIN32
	const size_t length = strlen(path);
	char* pattern = malloc(length + 3);
	if (!pattern) error("Failed to allocate the shared folder!");
	memcpy(pattern, path, length);
	memcpy(pattern + length, "\\*", 3);
	dir->find = FindFirstFileA(pattern, &dir->data);
	free(pattern);
	dir->pending = dir->find != INVALID_HANDLE_VALUE;
	if (!dir->pending && GetLastError() != ERROR_FILE_NOT_FOUND) {
		free(dir->path);
		free(dir);
		errno = ENOENT;
		return NULL;
	}
#else
	dir->dir = opendir(path);
	if (!dir->dir) {
		const int number = errno;
		free(dir->path);
		free(dir);
		errno = number;
		return NULL;
	}
#endif
	return dir;
}

// The next name in the directory, NULL at the end
static const char* share_dir_next(share_dir_t* dir) {
#ifdef _WIN32
	if (!dir->pending) {
		if (dir->find == INVALID_HANDLE_VALUE
			|| !FindNextFileA(dir->find, &dir->data))
			return NULL;
	}
	dir->pending = false;
	return dir->data.cFileName;
#else
	const struct dirent* entry = readdir(dir->dir);
	return entry ? entry->d_name : NULL;
#endif
}

static void share_dir_close(share_dir_t* dir) {
	if (!dir) return;
#ifdef _WIN32
	if (dir->find != INVALID_HANDLE_VALUE) FindClose(dir->find);
#else
	closedir(dir->dir);
#endif
	free(dir->path);
	free(dir);
}

// The absolute path with symbolic links followed (malloc'ed), NULL with
// errno set if there is none. '/' between names, on Windows too.
static char* share_real_path(const char* path) {
#ifdef _WIN32
	char* real = _fullpath(NULL, path, 0);
	if (!real) {
		errno = ENOENT;
		return NULL;
	}
	share_stat_t st;
	if (share_stat(real, &st) != 0) {
		free(real); // _fullpath doesn't look whether it is there
		errno = ENOENT;
		return NULL;
	}
	for (char* p = real; *p; p++)
		if (*p == '\\') *p = '/';
	return real;
#else
	return realpath(path, NULL);
#endif
}

// Writes what stdio holds of the file and has the host put it on its
// medium; false if it fails.
static bool share_sync_file(FILE* file) {
	if (fflush(file) != 0) return false;
#if defined(_WIN32)
	return _commit(_fileno(file)) == 0;
#elif defined(__APPLE__) && defined(F_FULLFSYNC)
	return fcntl(fileno(file), F_FULLFSYNC) != -1 || fsync(fileno(file)) == 0;
#else
	return fsync(fileno(file)) == 0;
#endif
}

static bool share_truncate_file(FILE* file, const uint64_t size) {
	if (fflush(file) != 0) return false;
#ifdef _WIN32
	return _chsize_s(_fileno(file), (__int64)size) == 0;
#else
	return ftruncate(fileno(file), (off_t)size) == 0;
#endif
}

// rename that replaces an existing file, as POSIX's does
static int share_rename(const char* from, const char* to) {
#ifdef _WIN32
	if (MoveFileExA(from, to, MOVEFILE_REPLACE_EXISTING)) return 0;
	switch (GetLastError()) {
		case ERROR_FILE_NOT_FOUND:
		case ERROR_PATH_NOT_FOUND:
			errno = ENOENT;
			break;
		case ERROR_ALREADY_EXISTS:
			errno = EEXIST;
			break;
		default:
			errno = EACCES;
	}
	return -1;
#else
	return rename(from, to);
#endif
}

// ---- paths --------------------------------------------------------------------

// Whether a name from a guest's path, or from a directory for the guest,
// can be used: not empty, not "." or "..", no control characters, no
// backslash or colon (they mean something to Windows), at most
// SHARE_NAME_MAX bytes.
static bool share_name_valid(const char* name, const size_t length) {
	if (length == 0 || length > SHARE_NAME_MAX) return false;
	if (name[0] == '.'
		&& (length == 1 || (length == 2 && name[1] == '.')))
		return false;
	for (size_t i = 0; i < length; i++) {
		const unsigned char c = (unsigned char)name[i];
		if (c < 0x20 || c == 0x7F || c == '\\' || c == ':' || c == '/')
			return false;
	}
	return true;
}

// Reads the guest's path at address (RAM or ROM) and makes the host's
// from it: the folder, then the path's names. Returns an error, or 0 with
// *host (malloc'ed) set and *is_root telling whether it is the folder
// itself.
static uint32_t share_host_path(share_t* share, const uint32_t address,
								char** host, bool* is_root) {
	char path[SHARE_PATH_MAX];
	size_t length = 0;
	for (;; length++) {
		if (length == SHARE_PATH_MAX) return SHARE_ERROR_PATH;
		uint32_t byte = 0;
		if (share->dma.read(share->dma.ctx, address + (uint32_t)length, 1, &byte))
			return SHARE_ERROR_ADDRESS;
		path[length] = (char)byte;
		if (!byte) break;
	}

	const size_t root = strlen(share->root);
	char* out = malloc(root + length + 2);
	if (!out) error("Failed to allocate the shared folder!");
	memcpy(out, share->root, root);
	size_t used = root;
	*is_root = true;
	// names between slashes; empty ones (//, a leading or trailing /) are
	// left out
	for (size_t start = 0; start < length;) {
		size_t end = start;
		while (end < length && path[end] != '/') end++;
		if (end > start) {
			if (!share_name_valid(&path[start], end - start)) {
				free(out);
				return SHARE_ERROR_PATH;
			}
			out[used++] = '/';
			memcpy(&out[used], &path[start], end - start);
			used += end - start;
			*is_root = false;
		}
		start = end + 1;
	}
	out[used] = '\0';
	*host = out;
	return SHARE_ERROR_NONE;
}

// Whether the host path stays in the folder once symbolic links are
// followed: the path itself if it is there, otherwise the directory it
// would be made in. The guest can't make links, but the host's user can.
// (Windows: links are not followed here.)
static uint32_t share_check_inside(const share_t* share, const char* host) {
	char* real = share_real_path(host);
	if (!real && errno == ENOENT) {
		// to be made: its directory must be there
		const char* slash = strrchr(host, '/');
		const size_t length = slash ? (size_t)(slash - host) : 0;
		char* parent = malloc(length + 1);
		if (!parent) error("Failed to allocate the shared folder!");
		memcpy(parent, host, length);
		parent[length] = '\0';
		real = share_real_path(parent);
		free(parent);
	}
	if (!real) return share_errno(errno);
	const size_t root = strlen(share->root);
	// the folder itself, or under it ("/" or "C:/" ends with the slash)
	const bool inside = strncmp(real, share->root, root) == 0
					 && (real[root] == '\0' || real[root] == '/'
						 || share->root[root - 1] == '/');
	free(real);
	return inside ? SHARE_ERROR_NONE : SHARE_ERROR_OUTSIDE;
}

// share_host_path and share_check_inside together
static uint32_t share_resolve(share_t* share, const uint32_t address,
							  char** host, bool* is_root) {
	uint32_t error = share_host_path(share, address, host, is_root);
	if (error) return error;
	error = share_check_inside(share, *host);
	if (error) {
		free(*host);
		*host = NULL;
	}
	return error;
}

// ---- records ------------------------------------------------------------------

static bool share_dma_put(share_t* share, const uint32_t address,
						  const uint8_t* bytes, const uint32_t length) {
	for (uint32_t i = 0; i < length; i++)
		if (share->dma.write(share->dma.ctx, address + i, 1, bytes[i]))
			return false;
	return true;
}

static void share_put32(uint8_t* p, const uint32_t value) {
	for (int i = 0; i < 4; i++) p[i] = (uint8_t)(value >> (8 * i));
}

// The STAT record of what the host path is; a link that leads out of the
// folder, or nowhere, is "other" and tells nothing more.
static void share_make_stat(const share_t* share, const char* host,
							uint8_t record[SHARE_STAT_SIZE]) {
	memset(record, 0, SHARE_STAT_SIZE);
	share_stat_t st;
	if (share_check_inside(share, host) || share_stat(host, &st) != 0) {
		share_put32(record, SHARE_TYPE_OTHER);
		return;
	}
	const uint32_t type = S_ISDIR(st.st_mode)	? SHARE_TYPE_DIRECTORY
						: S_ISREG(st.st_mode) ? SHARE_TYPE_FILE
											  : SHARE_TYPE_OTHER;
	const uint64_t size = type == SHARE_TYPE_FILE ? (uint64_t)st.st_size : 0;
	const uint64_t mtime = st.st_mtime > 0 ? (uint64_t)st.st_mtime : 0;
	share_put32(&record[0x00], type);
	share_put32(&record[0x08], (uint32_t)size);
	share_put32(&record[0x0C], (uint32_t)(size >> 32));
	share_put32(&record[0x10], (uint32_t)mtime);
	share_put32(&record[0x14], (uint32_t)(mtime >> 32));
}

// ---- commands -----------------------------------------------------------------

static bool share_handle_valid(const share_t* share) {
	return share->current < SHARE_HANDLE_COUNT;
}

static share_handle_t* share_file(share_t* share) {
	if (!share_handle_valid(share)) return NULL;
	share_handle_t* handle = &share->handle[share->current];
	return handle->file ? handle : NULL;
}

static share_dir_t* share_directory(share_t* share) {
	if (!share_handle_valid(share)) return NULL;
	return share->handle[share->current].directory;
}

static void share_close_handle(share_handle_t* handle) {
	if (handle->file) fclose(handle->file);
	share_dir_close(handle->directory);
	handle->file = NULL;
	handle->directory = NULL;
	handle->writable = false;
}

static uint32_t share_open_command(share_t* share) {
	const uint32_t flags = share->flags;
	const bool directory = flags & SHARE_FLAG_DIRECTORY;
	const bool write = flags & SHARE_FLAG_WRITE;
	if ((flags & ~SHARE_FLAGS_MASK)
		|| (directory && flags != SHARE_FLAG_DIRECTORY)
		|| (!write && (flags & (SHARE_FLAG_CREATE | SHARE_FLAG_TRUNCATE)))
		|| ((flags & SHARE_FLAG_EXCLUSIVE) && !(flags & SHARE_FLAG_CREATE)))
		return SHARE_ERROR_COMMAND;
	if (write && share->readonly) return SHARE_ERROR_READONLY;

	int free_handle = -1;
	for (int i = SHARE_HANDLE_COUNT - 1; i >= 0; i--)
		if (!share->handle[i].file && !share->handle[i].directory)
			free_handle = i;
	if (free_handle < 0) return SHARE_ERROR_NO_HANDLE;
	share_handle_t* handle = &share->handle[free_handle];

	char* host = NULL;
	bool is_root = false;
	uint32_t error = share_resolve(share, share->path, &host, &is_root);
	if (error) return error;

	if (directory) {
		share_stat_t st;
		if (share_stat(host, &st) != 0)
			error = share_errno(errno);
		else if (!S_ISDIR(st.st_mode))
			error = SHARE_ERROR_TYPE;
		else if (!(handle->directory = share_dir_open(host)))
			error = share_errno(errno);
		free(host);
		if (!error) share->current = (uint32_t)free_handle;
		return error;
	}

	int oflags = (write ? O_RDWR : O_RDONLY) | SHARE_O_BINARY;
	if (flags & SHARE_FLAG_CREATE) oflags |= O_CREAT;
	if (flags & SHARE_FLAG_EXCLUSIVE) oflags |= O_EXCL;
	if (flags & SHARE_FLAG_TRUNCATE) oflags |= O_TRUNC;
#ifdef O_NONBLOCK
	oflags |= O_NONBLOCK; // a FIFO mustn't hang the machine
#endif
	const int fd = is_root ? -1 : share_open_fd(host, oflags, 0666);
	const int number = is_root ? EISDIR : errno;
	free(host);
	if (fd < 0) return share_errno(number);

	share_stat_t st;
	if (share_fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
		share_close(fd);
		return SHARE_ERROR_TYPE;
	}
	handle->file = share_fdopen(fd, write ? "r+b" : "rb");
	if (!handle->file) {
		share_close(fd);
		return SHARE_ERROR_HOST;
	}
	handle->writable = write;
	share->current = (uint32_t)free_handle;
	return SHARE_ERROR_NONE;
}

static uint32_t share_close_command(share_t* share) {
	if (!share_file(share) && !share_directory(share))
		return SHARE_ERROR_HANDLE;
	share_close_handle(&share->handle[share->current]);
	return SHARE_ERROR_NONE;
}

// Bytes moved go on in ADDRESS and POSITION and off COUNT, and into RESULT,
// also when the move stops on an error.
static void share_moved(share_t* share, const uint32_t bytes) {
	share->address += bytes;
	share->position += bytes;
	share->count -= bytes;
	share->result = bytes;
}

static uint32_t share_read_file(share_t* share) {
	share_handle_t* handle = share_file(share);
	if (!handle) return SHARE_ERROR_HANDLE;
	if (share->position > INT64_MAX
		|| share_fseek(handle->file, (int64_t)share->position, SEEK_SET) != 0)
		return SHARE_ERROR_HOST;

	const uint32_t total =
		share->count < SHARE_MOVE_MAX ? share->count : SHARE_MOVE_MAX;
	uint8_t chunk[4096];
	uint32_t moved = 0;
	uint32_t error = SHARE_ERROR_NONE;
	while (moved < total) {
		const uint32_t want = total - moved < sizeof(chunk)
								? total - moved
								: (uint32_t)sizeof(chunk);
		const size_t got = fread(chunk, 1, want, handle->file);
		uint32_t put = 0;
		while (put < got) {
			if (share->dma.write(
						share->dma.ctx, share->address + moved + put, 1, chunk[put])) {
				error = SHARE_ERROR_ADDRESS;
				break;
			}
			put++;
		}
		moved += put;
		if (error) break;
		if (got < want) {
			if (ferror(handle->file)) error = SHARE_ERROR_HOST;
			break; // the end of the file
		}
	}
	clearerr(handle->file);
	share_moved(share, moved);
	return error;
}

static uint32_t share_write_file(share_t* share) {
	share_handle_t* handle = share_file(share);
	if (!handle) return SHARE_ERROR_HANDLE;
	if (!handle->writable) return SHARE_ERROR_READONLY;
	if (share->position > INT64_MAX
		|| share_fseek(handle->file, (int64_t)share->position, SEEK_SET) != 0)
		return SHARE_ERROR_HOST;

	const uint32_t total =
		share->count < SHARE_MOVE_MAX ? share->count : SHARE_MOVE_MAX;
	uint8_t chunk[4096];
	uint32_t moved = 0;
	uint32_t error = SHARE_ERROR_NONE;
	while (moved < total && !error) {
		const uint32_t want = total - moved < sizeof(chunk)
								? total - moved
								: (uint32_t)sizeof(chunk);
		uint32_t got = 0;
		for (; got < want; got++) {
			uint32_t byte = 0;
			if (share->dma.read(
						share->dma.ctx, share->address + moved + got, 1, &byte)) {
				error = SHARE_ERROR_ADDRESS;
				break;
			}
			chunk[got] = (uint8_t)byte;
		}
		// what was gathered before a DMA error still goes to the file
		const size_t written = fwrite(chunk, 1, got, handle->file);
		moved += (uint32_t)written;
		if (written < got) error = SHARE_ERROR_HOST;
	}
	if (fflush(handle->file) != 0 && !error) error = SHARE_ERROR_HOST;
	share_moved(share, moved);
	return error;
}

static uint32_t share_stat_command(share_t* share) {
	if (share->count < SHARE_STAT_SIZE) return SHARE_ERROR_SIZE;
	char* host = NULL;
	bool is_root = false;
	const uint32_t error = share_resolve(share, share->path, &host, &is_root);
	if (error) return error;
	share_stat_t st;
	const bool found = share_stat(host, &st) == 0;
	const int number = errno;
	uint8_t record[SHARE_STAT_SIZE];
	if (found) share_make_stat(share, host, record);
	free(host);
	if (!found) return share_errno(number);
	if (!share_dma_put(share, share->address, record, SHARE_STAT_SIZE))
		return SHARE_ERROR_ADDRESS;
	share->result = SHARE_STAT_SIZE;
	return SHARE_ERROR_NONE;
}

static uint32_t share_readdir(share_t* share) {
	share_dir_t* dir = share_directory(share);
	if (!dir) return SHARE_ERROR_HANDLE;
	if (share->count < SHARE_DIRENT_MAX) return SHARE_ERROR_SIZE;

	const char* name = NULL;
	while ((name = share_dir_next(dir))
		   && !share_name_valid(name, strlen(name))) {
		// ".", "..", and names the guest couldn't use are left out
	}
	if (!name) return SHARE_ERROR_NONE; // the end: RESULT is 0

	const size_t length = strlen(name);
	const size_t base = strlen(dir->path);
	char* host = malloc(base + length + 2);
	if (!host) error("Failed to allocate the shared folder!");
	memcpy(host, dir->path, base);
	host[base] = '/';
	memcpy(host + base + 1, name, length + 1);

	uint8_t record[SHARE_DIRENT_MAX];
	share_make_stat(share, host, record);
	free(host);
	memcpy(&record[SHARE_STAT_SIZE], name, length + 1);
	const uint32_t size = SHARE_STAT_SIZE + (uint32_t)length + 1;
	if (!share_dma_put(share, share->address, record, size))
		return SHARE_ERROR_ADDRESS;
	share->result = size;
	return SHARE_ERROR_NONE;
}

static uint32_t share_mkdir_command(share_t* share) {
	if (share->readonly) return SHARE_ERROR_READONLY;
	char* host = NULL;
	bool is_root = false;
	const uint32_t error = share_resolve(share, share->path, &host, &is_root);
	if (error) return error;
	const int result = is_root ? -1 : share_mkdir(host);
	const int number = is_root ? EEXIST : errno;
	free(host);
	return result == 0 ? SHARE_ERROR_NONE : share_errno(number);
}

static uint32_t share_remove(share_t* share) {
	if (share->readonly) return SHARE_ERROR_READONLY;
	char* host = NULL;
	bool is_root = false;
	const uint32_t error = share_host_path(share, share->path, &host, &is_root);
	if (error) return error;
	if (is_root) {
		free(host);
		return SHARE_ERROR_PATH;
	}
	// a link goes, not what it leads to; its directory must be inside
	const char* slash = strrchr(host, '/');
	char* parent = share_strdup(host);
	parent[slash - host] = '\0';
	const uint32_t outside = share_check_inside(share, parent);
	free(parent);
	if (outside) {
		free(host);
		return outside;
	}
	share_stat_t st;
	int result = share_lstat(host, &st);
	if (result == 0)
		result = S_ISDIR(st.st_mode) ? share_rmdir(host) : share_unlink(host);
	const int number = errno;
	free(host);
	return result == 0 ? SHARE_ERROR_NONE : share_errno(number);
}

static uint32_t share_rename_command(share_t* share) {
	if (share->readonly) return SHARE_ERROR_READONLY;
	char* from = NULL;
	char* to = NULL;
	bool from_root = false, to_root = false;
	uint32_t error = share_resolve(share, share->path, &from, &from_root);
	if (error) return error;
	error = share_resolve(share, share->path2, &to, &to_root);
	if (!error && (from_root || to_root)) error = SHARE_ERROR_PATH;
	if (!error && share_rename(from, to) != 0) error = share_errno(errno);
	free(from);
	free(to);
	return error;
}

static uint32_t share_truncate(share_t* share) {
	share_handle_t* handle = share_file(share);
	if (!handle) return SHARE_ERROR_HANDLE;
	if (!handle->writable) return SHARE_ERROR_READONLY;
	if (share->position > INT64_MAX) return SHARE_ERROR_HOST;
	return share_truncate_file(handle->file, share->position)
			 ? SHARE_ERROR_NONE
			 : SHARE_ERROR_HOST;
}

static uint32_t share_sync(share_t* share) {
	share_handle_t* handle = share_file(share);
	if (!handle) return SHARE_ERROR_HANDLE;
	if (!handle->writable) return SHARE_ERROR_NONE; // nothing to write
	return share_sync_file(handle->file) ? SHARE_ERROR_NONE : SHARE_ERROR_HOST;
}

static uint32_t share_run(share_t* share, const uint32_t command) {
	if (command < SHARE_COMMAND_OPEN || command > SHARE_COMMAND_SYNC)
		return SHARE_ERROR_COMMAND;
	if (!share->root) return SHARE_ERROR_NO_FOLDER;
	switch (command) {
		case SHARE_COMMAND_OPEN:
			return share_open_command(share);
		case SHARE_COMMAND_CLOSE:
			return share_close_command(share);
		case SHARE_COMMAND_READ:
			return share_read_file(share);
		case SHARE_COMMAND_WRITE:
			return share_write_file(share);
		case SHARE_COMMAND_STAT:
			return share_stat_command(share);
		case SHARE_COMMAND_READDIR:
			return share_readdir(share);
		case SHARE_COMMAND_MKDIR:
			return share_mkdir_command(share);
		case SHARE_COMMAND_REMOVE:
			return share_remove(share);
		case SHARE_COMMAND_RENAME:
			return share_rename_command(share);
		case SHARE_COMMAND_TRUNCATE:
			return share_truncate(share);
	}
	return share_sync(share);
}

// ---- the device ---------------------------------------------------------------

share_t* share_create(const bus_t dma, const char* root, const bool readonly) {
	share_t* share = (share_t*)calloc(1, sizeof(share_t));
	if (!share) error("Failed to allocate the shared folder!");
	share->dma = dma;
	share->readonly = readonly;
	if (root) {
		share_stat_t st;
		share->root = share_real_path(root);
		if (!share->root || share_stat(share->root, &st) != 0
			|| !S_ISDIR(st.st_mode))
			error("--share: %s is not a directory", root);
		// no trailing slash, except for "/" and "C:/"
		const size_t length = strlen(share->root);
		if (length > 1 && share->root[length - 1] == '/'
			&& share->root[length - 2] != ':')
			share->root[length - 1] = '\0';
		print("Shared folder %s%s", share->root, readonly ? ", read-only" : "");
	}
	share_reset(share);
	return share;
}

void share_destroy(share_t* share) {
	if (!share) return;
	share_close_handles(share);
	free(share->root);
	free(share);
	share = NULL;
}

void share_close_handles(share_t* share) {
	if (!share) return;
	for (int i = 0; i < SHARE_HANDLE_COUNT; i++)
		share_close_handle(&share->handle[i]);
}

int share_open_handles(const share_t* share) {
	int open = 0;
	for (int i = 0; i < SHARE_HANDLE_COUNT; i++)
		if (share->handle[i].file || share->handle[i].directory) open++;
	return open;
}

void share_reset(share_t* share) {
	if (!share) return;
	share_close_handles(share);
	share->error = SHARE_ERROR_NONE;
	share->current = 0;
	share->path = 0;
	share->path2 = 0;
	share->address = 0;
	share->count = 0;
	share->position = 0;
	share->flags = 0;
	share->result = 0;
}

bool share_read(share_t* share, const uint32_t offset, const uint8_t size,
				uint32_t* value) {
	(void)size; // narrower loads get the low bits
	switch (offset) {
		case SHARE_REG_STATUS:
			*value = (share->root ? SHARE_STATUS_PRESENT : 0)
				   | (share->root && share->readonly ? SHARE_STATUS_READONLY
													 : 0);
			return false;
		case SHARE_REG_COMMAND:
			*value = 0; // write-only
			return false;
		case SHARE_REG_ERROR:
			*value = share->error;
			return false;
		case SHARE_REG_HANDLE:
			*value = share->current;
			return false;
		case SHARE_REG_PATH:
			*value = share->path;
			return false;
		case SHARE_REG_PATH2:
			*value = share->path2;
			return false;
		case SHARE_REG_ADDRESS:
			*value = share->address;
			return false;
		case SHARE_REG_COUNT:
			*value = share->count;
			return false;
		case SHARE_REG_POSITION_LO:
			*value = (uint32_t)share->position;
			return false;
		case SHARE_REG_POSITION_HI:
			*value = (uint32_t)(share->position >> 32);
			return false;
		case SHARE_REG_FLAGS:
			*value = share->flags;
			return false;
		case SHARE_REG_RESULT:
			*value = share->result;
			return false;
		case SHARE_REG_HANDLES:
			*value = SHARE_HANDLE_COUNT;
			return false;
	}
	return true;
}

bool share_write(share_t* share, const uint32_t offset, const uint8_t size,
				 const uint32_t value) {
	(void)size;
	switch (offset) {
		case SHARE_REG_STATUS:
		case SHARE_REG_ERROR:
		case SHARE_REG_RESULT:
		case SHARE_REG_HANDLES:
			return false; // read-only, writes are ignored
		case SHARE_REG_COMMAND:
			share->result = 0;
			share->error = share_run(share, value);
			return false;
		case SHARE_REG_HANDLE:
			share->current = value;
			return false;
		case SHARE_REG_PATH:
			share->path = value;
			return false;
		case SHARE_REG_PATH2:
			share->path2 = value;
			return false;
		case SHARE_REG_ADDRESS:
			share->address = value;
			return false;
		case SHARE_REG_COUNT:
			share->count = value;
			return false;
		case SHARE_REG_POSITION_LO:
			share->position = (share->position & ~(uint64_t)UINT32_MAX) | value;
			return false;
		case SHARE_REG_POSITION_HI:
			share->position =
				(share->position & UINT32_MAX) | (uint64_t)value << 32;
			return false;
		case SHARE_REG_FLAGS:
			share->flags = value;
			return false;
	}
	return true;
}
