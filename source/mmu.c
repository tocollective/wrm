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
}

void mmu_reset(mmu_t* mmu) {
	if (!mmu) return;
	mmu->ptbr = 0;
	mmu_flush(mmu);
}

void mmu_set_ptbr(mmu_t* mmu, const uint32_t value) {
	if (!mmu) return;
	const uint32_t next = value & MMU_PTBR_MASK;
	const uint8_t old_asid = (uint8_t)((mmu->ptbr & MMU_PTBR_ASID) >> 4);
	const uint8_t new_asid = (uint8_t)((next & MMU_PTBR_ASID) >> 4);
	// Reusing an ASID explicitly refreshes that context. Switching to a
	// different ASID leaves its cached translations available on return.
	if (old_asid == new_asid) mmu_invalidate_asid(mmu, new_asid);
	mmu->ptbr = next;
}

void mmu_flush(mmu_t* mmu) {
	if (!mmu) return;
	memset(mmu->tlb, 0, sizeof(mmu->tlb));
	mmu->next_victim = 0;
}

void mmu_invalidate(mmu_t* mmu, const uint32_t address) {
	if (!mmu) return;
	const uint32_t vpn = address >> MMU_PAGE_SHIFT;
	const uint8_t asid = (uint8_t)((mmu->ptbr & MMU_PTBR_ASID) >> 4);
	for (size_t i = 0; i < MMU_TLB_SIZE; i++) {
		mmu_tlb_entry_t* entry = &mmu->tlb[i];
		if (entry->valid && entry->vpn == vpn
			&& (entry->global || entry->asid == asid))
			entry->valid = false;
	}
}

void mmu_invalidate_asid(mmu_t* mmu, const uint8_t asid) {
	if (!mmu) return;
	for (size_t i = 0; i < MMU_TLB_SIZE; i++)
		if (!mmu->tlb[i].global && mmu->tlb[i].asid == asid)
			mmu->tlb[i].valid = false;
}

// Page table walks never read device registers.
static bool mmu_read_entry(mmu_t* mmu, const uint32_t address,
						   uint32_t* entry) {
	return mmu->bus.fetch(mmu->bus.ctx, address, 4, entry);
}

static bool mmu_walk(mmu_t* mmu, const uint32_t address,
					 mmu_tlb_entry_t* entry) {
	const uint32_t dir = mmu->ptbr & MMU_PTBR_BASE;
	const uint32_t dir_index = address >> MMU_SUPERPAGE_SHIFT;
	const uint32_t table_index = (address >> MMU_PAGE_SHIFT) & MMU_INDEX_MASK;
	uint32_t pte_address = dir + dir_index * 4;
	uint32_t pte = 0;
	if (mmu_read_entry(mmu, pte_address, &pte) || !(pte & MMU_PTE_V))
		return true;

	const bool directory_global = (pte & MMU_PTE_G) != 0;
	uint32_t frame;
	if (pte & MMU_PTE_RWX) {
		if (pte & MMU_SUPERPAGE_MASK & MMU_PTE_FRAME) return true;
		frame = (pte & ~MMU_SUPERPAGE_MASK) | (address & MMU_SUPERPAGE_MASK);
	} else {
		pte_address = (pte & MMU_PTE_FRAME) + table_index * 4;
		if (mmu_read_entry(mmu, pte_address, &pte)
			|| !(pte & MMU_PTE_V) || !(pte & MMU_PTE_RWX))
			return true;
		frame = pte;
	}

	*entry = (mmu_tlb_entry_t){
		.valid = true,
		.vpn = address >> MMU_PAGE_SHIFT,
		.ppn = frame >> MMU_PAGE_SHIFT,
		.flags = pte & (MMU_PTE_RWX | MMU_PTE_U | MMU_PTE_A | MMU_PTE_D),
		.asid = (uint8_t)((mmu->ptbr & MMU_PTBR_ASID) >> 4),
		.global = directory_global || (pte & MMU_PTE_G) != 0,
		.pte_address = pte_address,
	};
	return false;
}

static bool mmu_translate_impl(mmu_t* mmu, const uint32_t address,
							   const mmu_access_t access, const bool user,
							   const bool dirty, uint32_t* physical) {
	if (!(mmu->ptbr & MMU_PTBR_ENABLE)) {
		*physical = address;
		return false;
	}

	const uint32_t vpn = address >> MMU_PAGE_SHIFT;
	const uint8_t asid = (uint8_t)((mmu->ptbr & MMU_PTBR_ASID) >> 4);
	mmu_tlb_entry_t* entry = NULL;
	for (size_t i = 0; i < MMU_TLB_SIZE; i++) {
		mmu_tlb_entry_t* candidate = &mmu->tlb[i];
		if (candidate->valid && candidate->vpn == vpn
			&& (candidate->global || candidate->asid == asid)) {
			entry = candidate;
			break;
		}
	}
	if (!entry) {
		for (size_t i = 0; i < MMU_TLB_SIZE; i++)
			if (!mmu->tlb[i].valid) {
				entry = &mmu->tlb[i];
				break;
			}
		if (!entry) {
			entry = &mmu->tlb[mmu->next_victim];
			mmu->next_victim = (mmu->next_victim + 1) % MMU_TLB_SIZE;
		}
		mmu_tlb_entry_t walked;
		if (mmu_walk(mmu, address, &walked)) return true;
		*entry = walked;
	}

	if ((entry->flags & access) != access) return true;
	if (user && !(entry->flags & MMU_PTE_U)) return true;

	const uint8_t needed = MMU_PTE_A
		| ((dirty && (access & MMU_ACCESS_WRITE)) ? MMU_PTE_D : 0);
	if ((entry->flags & needed) != needed) {
		uint32_t pte = 0;
		if (mmu_read_entry(mmu, entry->pte_address, &pte)
			|| mmu->bus.write(mmu->bus.ctx, entry->pte_address, 4,
							  pte | needed))
			return true;
		entry->flags |= needed;
	}
	*physical = (entry->ppn << MMU_PAGE_SHIFT) | (address & MMU_PAGE_MASK);
	return false;
}

bool mmu_translate(mmu_t* mmu, const uint32_t address,
				   const mmu_access_t access, const bool user,
				   uint32_t* physical) {
	return mmu_translate_impl(mmu, address, access, user, true, physical);
}

bool mmu_translate_probe(mmu_t* mmu, const uint32_t address,
						 const mmu_access_t access, const bool user,
						 uint32_t* physical) {
	return mmu_translate_impl(mmu, address, access, user, false, physical);
}
