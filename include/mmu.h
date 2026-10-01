#ifndef WRM_MMU_H
#define WRM_MMU_H
#include "common.h"

#include "bus.h"

// Paging unit of the CPU: two-level page tables, 4KB pages and 4MB
// superpages (see docs/INSTRUCTIONS.md#memory-management).
// Virtual address: [31:22] directory index, [21:12] table index,
// [11:0] page offset.
#define MMU_PAGE_SHIFT 12
#define MMU_PAGE_SIZE (1u << MMU_PAGE_SHIFT)
#define MMU_PAGE_MASK (MMU_PAGE_SIZE - 1)
#define MMU_SUPERPAGE_SHIFT 22
#define MMU_SUPERPAGE_MASK ((1u << MMU_SUPERPAGE_SHIFT) - 1)
#define MMU_INDEX_MASK 0x3FF // 1024 entries per table

// PTBR control register
#define MMU_PTBR_ENABLE 0x01 // translation on
#define MMU_PTBR_ASID 0xFF0 // 8-bit address-space identifier in bits 11:4
#define MMU_PTBR_BASE (~MMU_PAGE_MASK) // physical address of the directory
#define MMU_PTBR_MASK (MMU_PTBR_BASE | MMU_PTBR_ASID | MMU_PTBR_ENABLE)

// Page directory / table entry: [31:12] physical page, [7:0] flags
#define MMU_PTE_V 0x01 // valid
#define MMU_PTE_R 0x02 // readable
#define MMU_PTE_W 0x04 // writable
#define MMU_PTE_X 0x08 // executable
#define MMU_PTE_U 0x10 // accessible in user mode
#define MMU_PTE_A 0x20 // accessed
#define MMU_PTE_D 0x40 // written
#define MMU_PTE_G 0x80 // shared by every ASID
#define MMU_PTE_RWX (MMU_PTE_R | MMU_PTE_W | MMU_PTE_X)
#define MMU_PTE_FRAME (~MMU_PAGE_MASK)

// what an access needs from the page
typedef enum mmu_access {
	MMU_ACCESS_READ = MMU_PTE_R,
	MMU_ACCESS_WRITE = MMU_PTE_W,
	MMU_ACCESS_EXECUTE = MMU_PTE_X,
} mmu_access_t;

// Fully associative, ASID-tagged translation cache
#define MMU_TLB_SIZE 64

typedef struct mmu_tlb_entry {
	bool valid;
	uint32_t vpn; // virtual page number
	uint32_t ppn; // physical page number
	uint8_t flags; // permissions and cached A/D state
	uint8_t asid;
	bool global;
	uint32_t pte_address; // physical address of the leaf PTE
} mmu_tlb_entry_t;

typedef struct mmu {
	uint32_t ptbr;
	mmu_tlb_entry_t tlb[MMU_TLB_SIZE];
	uint8_t next_victim;
	bus_t bus; // physical memory, for page table walks
} mmu_t;

mmu_t* mmu_create(const bus_t bus);
void mmu_destroy(mmu_t* mmu);

void mmu_reset(mmu_t* mmu);
void mmu_set_ptbr(mmu_t* mmu, const uint32_t value);
void mmu_flush(mmu_t* mmu);
void mmu_invalidate(mmu_t* mmu, const uint32_t address); // one 4KB page
// every entry of the ASID except the global ones
void mmu_invalidate_asid(mmu_t* mmu, const uint8_t asid);

// Translates a virtual address; returns true on page fault.
// In user mode only pages with MMU_PTE_U are accessible.
bool mmu_translate(mmu_t* mmu, const uint32_t address,
				   const mmu_access_t access, const bool user,
				   uint32_t* physical);
// Like mmu_translate, but does not mark the page dirty (failed SC).
bool mmu_translate_probe(mmu_t* mmu, const uint32_t address,
						 const mmu_access_t access, const bool user,
						 uint32_t* physical);

#endif // WRM_MMU_H
