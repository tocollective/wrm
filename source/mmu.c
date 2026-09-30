#include "mmu.h"

#include <string.h>

mmu_t* mmu_create(const bus_t bus) {
	mmu_t* mmu = (mmu_t*)calloc(1, sizeof(mmu_t));
	if (!mmu) error("Failed to allocate MMU!");
	mmu->bus = bus;
	mmu_reset(mmu);
	return mmu;
}

void mmu_destroy(mmu_t* mmu) {
	if (!mmu) return;
	free(mmu);
	mmu = NULL;
}

void mmu_reset(mmu_t* mmu) {
	if (!mmu) return;
	mmu_set_ptbr(mmu, 0);
}

void mmu_set_ptbr(mmu_t* mmu, const uint32_t value) {
	if (!mmu) return;
	mmu->ptbr = value & MMU_PTBR_MASK;
	mmu_flush(mmu);
}

void mmu_flush(mmu_t* mmu) {
	if (!mmu) return;
	memset(mmu->tlb, 0, sizeof(mmu->tlb));
}

void mmu_invalidate(mmu_t* mmu, const uint32_t address) {
	if (!mmu) return;
	const uint32_t vpn = address >> MMU_PAGE_SHIFT;
	mmu_tlb_entry_t* entry = &mmu->tlb[vpn % MMU_TLB_SIZE];
	if (entry->vpn == vpn) entry->valid = false;
}

// returns true when the entry can't be read; entries in the I/O region
// can't, so a walk never touches a device
static bool mmu_read_entry(mmu_t* mmu, const uint32_t table,
						   const uint32_t index, uint32_t* entry) {
	return mmu->bus.fetch(mmu->bus.ctx, table + index * 4, 4, entry);
}

// Walks the page tables for address and fills the TLB entry;
// returns true on page fault, leaving the entry untouched.
static bool mmu_walk(mmu_t* mmu, const uint32_t address,
					 mmu_tlb_entry_t* entry) {
	const uint32_t dir = mmu->ptbr & MMU_PTBR_BASE;
	const uint32_t dir_index = address >> MMU_SUPERPAGE_SHIFT;
	const uint32_t table_index = (address >> MMU_PAGE_SHIFT) & MMU_INDEX_MASK;

	uint32_t pte = 0;
	if (mmu_read_entry(mmu, dir, dir_index, &pte)) return true;
	if (!(pte & MMU_PTE_V)) return true;

	uint32_t frame = 0;
	if (pte & MMU_PTE_RWX) {
		// 4MB superpage, must be aligned to 4MB
		if (pte & MMU_SUPERPAGE_MASK & MMU_PTE_FRAME) return true;
		frame = (pte & ~MMU_SUPERPAGE_MASK) | (address & MMU_SUPERPAGE_MASK);
	} else {
		const uint32_t table = pte & MMU_PTE_FRAME;
		if (mmu_read_entry(mmu, table, table_index, &pte)) return true;
		if (!(pte & MMU_PTE_V) || !(pte & MMU_PTE_RWX)) return true;
		frame = pte;
	}

	entry->valid = true;
	entry->vpn = address >> MMU_PAGE_SHIFT;
	entry->ppn = frame >> MMU_PAGE_SHIFT;
	entry->flags = pte & (MMU_PTE_RWX | MMU_PTE_U);
	return false;
}

bool mmu_translate(mmu_t* mmu, const uint32_t address,
				   const mmu_access_t access, const bool user,
				   uint32_t* physical) {
	if (!(mmu->ptbr & MMU_PTBR_ENABLE)) {
		*physical = address;
		return false;
	}

	const uint32_t vpn = address >> MMU_PAGE_SHIFT;
	mmu_tlb_entry_t* entry = &mmu->tlb[vpn % MMU_TLB_SIZE];
	if (!entry->valid || entry->vpn != vpn) {
		if (mmu_walk(mmu, address, entry)) return true;
	}

	if (!(entry->flags & access)) return true;
	if (user && !(entry->flags & MMU_PTE_U)) return true;
	*physical = (entry->ppn << MMU_PAGE_SHIFT) | (address & MMU_PAGE_MASK);
	return false;
}
