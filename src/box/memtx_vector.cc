/*
 * Copyright 2010-2016, Tarantool AUTHORS, please see AUTHORS file.
 *
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include "memtx_vector.h"

#include <math.h>
#include <new>
#include <stdlib.h>
#include <string.h>

#include <small/matras.h>
#include <small/mempool.h>

#include "fiber.h"
#include "index.h"
#include "memtx_engine.h"
#include "memtx_index.h"
#include "memtx_tx.h"
#include "schema.h"
#include "space.h"
#include "trivia/util.h"
#include "tt_static.h"
#include "tuple.h"
#include "txn.h"

#define USEARCH_USE_FP16LIB 0
#define USEARCH_USE_SIMSIMD 0
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-W#warnings"
#pragma clang diagnostic ignored "-Wunused-parameter"
#elif defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wcpp"
#pragma GCC diagnostic ignored "-Wunused-parameter"
#endif
#ifdef prefetch
#undef prefetch
#define MEMTX_VECTOR_RESTORE_PREFETCH
#endif
#ifndef NDEBUG
#define MEMTX_VECTOR_RESTORE_NDEBUG
#define NDEBUG
#endif
#include "usearch/index_dense.hpp"
#ifdef MEMTX_VECTOR_RESTORE_NDEBUG
#undef NDEBUG
#endif
#ifdef MEMTX_VECTOR_RESTORE_PREFETCH
#define prefetch(addr, ...) (__builtin_prefetch(addr, __VA_ARGS__))
#endif
#if defined(__clang__)
#pragma clang diagnostic pop
#elif defined(__GNUC__)
#pragma GCC diagnostic pop
#endif
/*
 * On Linux, USearch pulls in <elf.h> via <sys/auxv.h>, which defines EV_NONE
 * as a macro and conflicts with libev enum members in subsequent includes.
 */
#ifdef EV_NONE
#undef EV_NONE
#endif

struct vector_hash_entry {
	struct tuple *tuple;
	uint32_t id;
};

#define mh_int_t uint32_t
#define mh_arg_t int

#if UINTPTR_MAX == 0xffffffff
#define mh_hash_key(a, arg) ((uintptr_t)(a))
#else
#define mh_hash_key(a, arg) ((uint32_t)(((uintptr_t)(a)) >> 33 ^ \
					((uintptr_t)(a)) ^ \
					((uintptr_t)(a)) << 11))
#endif
#define mh_hash(a, arg) mh_hash_key((a)->tuple, arg)
#define mh_cmp(a, b, arg) ((a)->tuple != (b)->tuple)
#define mh_cmp_key(a, b, arg) ((a) != (b)->tuple)

#define mh_node_t struct vector_hash_entry
#define mh_key_t struct tuple *
#define mh_name _vector_index
#define MH_SOURCE 1
#include <salad/mhash.h>
/*
 * `mhash.h` undefines `mh_int_t` at the end of inclusion, but iterator macros
 * like `mh_foreach()` still expand to this token afterwards.
 */
#define mh_int_t uint32_t

using usearch_index_t = unum::usearch::index_dense_gt<uint32_t, uint32_t>;
using usearch_metric_kind_t = unum::usearch::metric_kind_t;
using usearch_metric_t = unum::usearch::metric_punned_t;
using usearch_index_limits_t = unum::usearch::index_limits_t;
using usearch_index_config_t = unum::usearch::index_dense_config_t;
using usearch_scalar_kind_t = unum::usearch::scalar_kind_t;

enum {
	SPARE_ID_END = UINT32_MAX,
	VECTOR_INITIAL_BATCH = 32,
};

struct memtx_vector_index {
	struct index base;
	usearch_index_t index;
	struct matras id_to_tuple;
	struct mh_vector_index_t *tuple_to_id;
	uint32_t spare_id;
	uint32_t dimension;
};

enum vector_iterator_type {
	VECTOR_ITERATOR_ALL = 0,
	VECTOR_ITERATOR_NEIGHBOR,
};

struct vector_index_iterator {
	struct iterator base; /* Must be the first member. */
	struct mempool *pool;
	enum vector_iterator_type type;
	struct tuple **tuples;
	size_t tuple_count;
	size_t tuple_capacity;
	size_t position;
	size_t fetched_count;
	float *query;
	size_t search_limit;
};

static_assert(sizeof(struct vector_index_iterator) <= MEMTX_ITERATOR_SIZE,
	      "sizeof(struct vector_index_iterator) must be less than or equal "
	      "to MEMTX_ITERATOR_SIZE");

struct vector_id_reservation {
	uint32_t id;
	bool from_spare;
};

static struct vector_index_iterator *
vector_index_iterator(struct iterator *it)
{
	return (struct vector_index_iterator *)it;
}

static void
memtx_vector_index_diag_set_usearch_error(const char *what, const char *message)
{
	diag_set(IllegalParams,
		 tt_sprintf("usearch %s failed: %s", what,
			    message == NULL ? "unknown error" : message));
}

static float *
memtx_vector_alloc(size_t count, const char *what)
{
	size_t size = count * sizeof(float);
	float *data = (float *)malloc(size);
	if (data == NULL) {
		diag_set(OutOfMemory, size, "malloc", what);
		return NULL;
	}
	return data;
}

static struct tuple *
memtx_vector_index_value_to_tuple(struct memtx_vector_index *index,
				  uint32_t value)
{
	void *mem = matras_get(&index->id_to_tuple, value);
	return *(struct tuple **)mem;
}

static int
memtx_vector_decode_array(float *out, uint32_t dimension, const char *data,
			  const char *what)
{
	if (data == NULL || mp_typeof(*data) != MP_ARRAY) {
		diag_set(IllegalParams, tt_sprintf("%s must be an array", what));
		return -1;
	}

	uint32_t count = mp_decode_array(&data);
	if (count != dimension) {
		diag_set(IllegalParams,
			 tt_sprintf("%s vector must contain %u numbers, got %u",
				    what, dimension, count));
		return -1;
	}

	for (uint32_t i = 0; i < count; i++) {
		double value;
		if (mp_read_double(&data, &value) != 0) {
			diag_set(IllegalParams,
				 tt_sprintf("%s vector element %u must be a "
					    "number", what, i + 1));
			return -1;
		}
		if (!isfinite(value)) {
			diag_set(IllegalParams,
				 tt_sprintf("%s vector element %u must be "
					    "finite", what, i + 1));
			return -1;
		}
		out[i] = (float)value;
	}
	return 0;
}

static int
memtx_vector_index_extract_vector(struct tuple *tuple, struct index_def *def,
				  float *out)
{
	assert(def->key_def->part_count == 1);
	assert(!def->key_def->is_multikey);

	const struct key_part *part = &def->key_def->parts[0];
	const char *field = tuple_field_by_part(tuple, def->key_def->parts,
						MULTIKEY_NONE);
	if (field == NULL) {
		diag_set(ClientError, ER_FIELD_TYPE,
			 int2str(part->fieldno + TUPLE_INDEX_BASE),
			 field_type_strs[FIELD_TYPE_ARRAY], "nil");
		return -1;
	}
	if (mp_typeof(*field) != MP_ARRAY) {
		diag_set(ClientError, ER_FIELD_TYPE,
			 int2str(part->fieldno + TUPLE_INDEX_BASE),
			 field_type_strs[FIELD_TYPE_ARRAY],
			 mp_type_strs[mp_typeof(*field)]);
		return -1;
	}
	const char *what =
		tt_sprintf("field %u", part->fieldno + TUPLE_INDEX_BASE);
	return memtx_vector_decode_array(out, def->opts.dimension, field, what);
}

static bool
memtx_vector_index_key_equal(struct tuple *a, struct tuple *b,
			     struct index_def *def)
{
	const char *a_field = tuple_field_by_part(a, def->key_def->parts,
						  MULTIKEY_NONE);
	const char *b_field = tuple_field_by_part(b, def->key_def->parts,
						  MULTIKEY_NONE);
	if (a_field == NULL || b_field == NULL)
		return a_field == b_field;
	const char *a_end = a_field;
	const char *b_end = b_field;
	mp_next(&a_end);
	mp_next(&b_end);
	size_t a_size = a_end - a_field;
	size_t b_size = b_end - b_field;
	return a_size == b_size && memcmp(a_field, b_field, a_size) == 0;
}

static usearch_metric_t
memtx_vector_index_make_metric(const struct index_def *def)
{
	usearch_metric_kind_t metric_kind;
	switch (def->opts.distance) {
	case INDEX_DISTANCE_TYPE_COSINE:
		metric_kind = usearch_metric_kind_t::cos_k;
		break;
	case INDEX_DISTANCE_TYPE_L2:
		metric_kind = usearch_metric_kind_t::l2sq_k;
		break;
	case INDEX_DISTANCE_TYPE_IP:
		metric_kind = usearch_metric_kind_t::ip_k;
		break;
	default:
		unreachable();
	}
	return usearch_metric_t::builtin(def->opts.dimension, metric_kind,
					 usearch_scalar_kind_t::f32_k);
}

static usearch_index_config_t
memtx_vector_index_make_config(const struct index_def *def)
{
	usearch_index_config_t config;
	config.connectivity = def->opts.m;
	config.expansion_add = def->opts.ef_construction;
	config.expansion_search = def->opts.ef_search;
	config.multi = false;
	config.enable_key_lookups = true;
	return config;
}

static int
memtx_vector_index_reserve_id(struct memtx_vector_index *index,
			      struct vector_id_reservation *reservation)
{
	if (index->spare_id != SPARE_ID_END) {
		reservation->id = index->spare_id;
		reservation->from_spare = true;
		void *mem = matras_get(&index->id_to_tuple, reservation->id);
		index->spare_id = *(uint32_t *)mem;
		return 0;
	}

	reservation->from_spare = false;
	if (matras_alloc(&index->id_to_tuple, &reservation->id) == NULL)
		return -1;
	return 0;
}

static void
memtx_vector_index_release_id(struct memtx_vector_index *index,
			      const struct vector_id_reservation *reservation)
{
	if (reservation->from_spare) {
		void *mem = matras_get(&index->id_to_tuple, reservation->id);
		*(uint32_t *)mem = index->spare_id;
		index->spare_id = reservation->id;
	} else {
		matras_dealloc(&index->id_to_tuple);
	}
}

static void
memtx_vector_index_commit_id(struct memtx_vector_index *index,
			     const struct vector_id_reservation *reservation,
			     struct tuple *tuple)
{
	void *mem = matras_get(&index->id_to_tuple, reservation->id);
	*(struct tuple **)mem = tuple;

	struct vector_hash_entry entry;
	entry.tuple = tuple;
	entry.id = reservation->id;
	mh_vector_index_put(index->tuple_to_id, &entry, NULL, 0);
}

static void
memtx_vector_index_unregister_tuple(struct memtx_vector_index *index,
				    struct tuple *tuple)
{
	uint32_t k = mh_vector_index_find(index->tuple_to_id, tuple, 0);
	if (k == mh_end(index->tuple_to_id))
		return;
	struct vector_hash_entry *entry =
		mh_vector_index_node(index->tuple_to_id, k);
	void *mem = matras_get(&index->id_to_tuple, entry->id);
	*(uint32_t *)mem = index->spare_id;
	index->spare_id = entry->id;
	mh_vector_index_del(index->tuple_to_id, k, 0);
}

static bool
memtx_vector_index_lookup_id(struct memtx_vector_index *index,
			     struct tuple *tuple, uint32_t *id)
{
	uint32_t k = mh_vector_index_find(index->tuple_to_id, tuple, 0);
	if (k == mh_end(index->tuple_to_id))
		return false;
	*id = mh_vector_index_node(index->tuple_to_id, k)->id;
	return true;
}

static void
memtx_vector_index_replace_tuple(struct memtx_vector_index *index,
				 struct tuple *old_tuple,
				 struct tuple *new_tuple)
{
	uint32_t k = mh_vector_index_find(index->tuple_to_id, old_tuple, 0);
	assert(k != mh_end(index->tuple_to_id));
	uint32_t id = mh_vector_index_node(index->tuple_to_id, k)->id;
	mh_vector_index_del(index->tuple_to_id, k, 0);

	void *mem = matras_get(&index->id_to_tuple, id);
	*(struct tuple **)mem = new_tuple;

	struct vector_hash_entry entry;
	entry.tuple = new_tuple;
	entry.id = id;
	mh_vector_index_put(index->tuple_to_id, &entry, NULL, 0);
}

static int
memtx_vector_index_add(struct memtx_vector_index *index,
		       const struct vector_id_reservation *reservation,
		       struct tuple *tuple, const float *vector)
{
	size_t needed = index->index.size() + 1;
	size_t capacity = index->index.capacity();
	if (needed > capacity) {
		size_t target = capacity == 0 ? 1 : capacity;
		while (target < needed)
			target *= 2;
		usearch_index_limits_t limits(target, 1);
		if (!index->index.try_reserve(limits)) {
			diag_set(OutOfMemory, 0, "usearch", "reserve");
			return -1;
		}
	}

	auto result = index->index.add(reservation->id, vector);
	if (!result) {
		memtx_vector_index_diag_set_usearch_error("insert",
							  result.error.what());
		return -1;
	}
	memtx_vector_index_commit_id(index, reservation, tuple);
	return 0;
}

static int
memtx_vector_index_remove_by_id(struct memtx_vector_index *index, uint32_t id)
{
	auto result = index->index.remove(id);
	if (!result) {
		memtx_vector_index_diag_set_usearch_error("delete",
							  result.error.what());
		return -1;
	}
	return 0;
}

static void
vector_index_iterator_destroy_tuples(struct vector_index_iterator *it)
{
	for (size_t i = 0; i < it->tuple_count; i++)
		tuple_unref(it->tuples[i]);
	free(it->tuples);
	it->tuples = NULL;
	it->tuple_count = 0;
	it->tuple_capacity = 0;
}

static void
vector_index_iterator_free(struct iterator *iterator)
{
	struct vector_index_iterator *it = vector_index_iterator(iterator);
	vector_index_iterator_destroy_tuples(it);
	free(it->query);
	mempool_free(it->pool, it);
}

static int
vector_index_iterator_reserve(struct vector_index_iterator *it, size_t count)
{
	if (count <= it->tuple_capacity)
		return 0;

	size_t capacity = it->tuple_capacity == 0 ? count :
			  MAX(count, it->tuple_capacity * 2);
	struct tuple **tuples = (struct tuple **)realloc(
		it->tuples, capacity * sizeof(*tuples));
	if (tuples == NULL) {
		diag_set(OutOfMemory, capacity * sizeof(*tuples),
			 "realloc", "vector iterator results");
		return -1;
	}
	it->tuples = tuples;
	it->tuple_capacity = capacity;
	return 0;
}

static int
vector_index_iterator_build_all(struct vector_index_iterator *it,
				struct memtx_vector_index *index)
{
	if (vector_index_iterator_reserve(it,
					  mh_size(index->tuple_to_id)) != 0)
		return -1;

	uint32_t pos;
	mh_foreach(index->tuple_to_id, pos) {
		struct tuple *tuple = mh_vector_index_node(index->tuple_to_id,
							   pos)->tuple;
		tuple_ref(tuple);
		it->tuples[it->tuple_count++] = tuple;
	}
	return 0;
}

static int
vector_index_iterator_fetch_more(struct vector_index_iterator *it,
				 struct memtx_vector_index *index)
{
	size_t total = index->index.size();
	if (it->search_limit >= total)
		return 0;

	size_t wanted = it->search_limit == 0 ? (size_t)VECTOR_INITIAL_BATCH :
			MIN(total, it->search_limit * 2);
	auto result = index->index.search(it->query, wanted);
	if (!result) {
		memtx_vector_index_diag_set_usearch_error("search",
							  result.error.what());
		return -1;
	}
	if (result.count <= it->fetched_count) {
		it->search_limit = wanted;
		return 0;
	}
	if (vector_index_iterator_reserve(it, it->tuple_count +
					      (result.count -
					       it->fetched_count)) != 0)
		return -1;

	for (size_t i = it->fetched_count; i < result.count; i++) {
		uint32_t id = result[i].member.key;
		struct tuple *tuple =
			memtx_vector_index_value_to_tuple(index, id);
		if (tuple == NULL)
			continue;
		tuple_ref(tuple);
		it->tuples[it->tuple_count++] = tuple;
	}
	it->fetched_count = result.count;
	it->search_limit = wanted;
	return 0;
}

static int
vector_index_iterator_next_internal(struct iterator *iterator,
				    struct tuple **ret)
{
	struct vector_index_iterator *it = vector_index_iterator(iterator);
	struct space *space;
	struct index *base;
	index_weak_ref_get_checked(&iterator->index_ref, &space, &base);
	struct memtx_vector_index *index = (struct memtx_vector_index *)base;

	for (;;) {
		if (it->position >= it->tuple_count) {
			if (it->type == VECTOR_ITERATOR_ALL) {
				*ret = NULL;
				return 0;
			}
			int rc = vector_index_iterator_fetch_more(it, index);
			if (rc != 0)
				return -1;
			if (it->position >= it->tuple_count) {
				*ret = NULL;
				return 0;
			}
		}
		struct tuple *tuple = it->tuples[it->position++];
		struct txn *txn = in_txn();
		*ret = memtx_tx_tuple_clarify(txn, space, tuple, base, 0);
		if (*ret != NULL)
			return 0;
	}
}

static void
memtx_vector_index_destroy(struct index *base)
{
	struct memtx_vector_index *index = (struct memtx_vector_index *)base;
	mh_vector_index_delete(index->tuple_to_id);
	matras_destroy(&index->id_to_tuple);
	delete index;
}

static void
memtx_vector_index_update_def(struct index *base)
{
	struct memtx_vector_index *index = (struct memtx_vector_index *)base;
	index->index.change_expansion_search(base->def->opts.ef_search);
}

static bool
memtx_vector_index_def_change_requires_rebuild(struct index *index,
					       const struct index_def *new_def)
{
	if (memtx_index_def_change_requires_rebuild(index, new_def))
		return true;
	if (index->def->opts.distance != new_def->opts.distance ||
	    index->def->opts.dimension != new_def->opts.dimension ||
	    index->def->opts.algorithm != new_def->opts.algorithm ||
	    index->def->opts.m != new_def->opts.m ||
	    index->def->opts.ef_construction !=
		    new_def->opts.ef_construction)
		return true;
	return false;
}

static ssize_t
memtx_vector_index_size(struct index *base)
{
	struct memtx_vector_index *index = (struct memtx_vector_index *)base;
	struct space *space = space_by_id(base->def->space_id);
	return (ssize_t)index->index.size() -
	       memtx_tx_track_count(in_txn(), space, base, ITER_GE, NULL, 0);
}

static ssize_t
memtx_vector_index_bsize(struct index *base)
{
	struct memtx_vector_index *index = (struct memtx_vector_index *)base;
	return (ssize_t)(index->index.memory_usage() +
			 matras_extent_count(&index->id_to_tuple) *
				 MEMTX_EXTENT_SIZE +
			 mh_vector_index_memsize(index->tuple_to_id));
}

static ssize_t
memtx_vector_index_count(struct index *base, enum iterator_type type,
			 const char *key, uint32_t part_count)
{
	if (type == ITER_ALL)
		return memtx_vector_index_size(base);
	return generic_index_count(base, type, key, part_count);
}

static int
memtx_vector_index_replace(struct index *base, struct tuple *old_tuple,
			   struct tuple *new_tuple, enum dup_replace_mode mode,
			   struct tuple **result, struct tuple **successor)
{
	(void)mode;
	struct memtx_vector_index *index = (struct memtx_vector_index *)base;
	*successor = NULL;

	if (old_tuple != NULL && new_tuple != NULL &&
	    memtx_vector_index_key_equal(old_tuple, new_tuple, base->def)) {
		memtx_vector_index_replace_tuple(index, old_tuple, new_tuple);
		*result = old_tuple;
		return 0;
	}

	float *new_vector = NULL;
	if (new_tuple != NULL) {
		new_vector = memtx_vector_alloc(index->dimension,
						"vector insert");
		if (new_vector == NULL)
			return -1;
		if (memtx_vector_index_extract_vector(new_tuple, base->def,
						      new_vector) != 0) {
			free(new_vector);
			return -1;
		}
	}

	uint32_t old_id = 0;
	if (old_tuple != NULL &&
	    !memtx_vector_index_lookup_id(index, old_tuple, &old_id))
		old_tuple = NULL;

	if (old_tuple == NULL && new_tuple == NULL) {
		free(new_vector);
		*result = NULL;
		return 0;
	}

	if (new_tuple == NULL) {
		if (memtx_vector_index_remove_by_id(index, old_id) != 0) {
			free(new_vector);
			return -1;
		}
		memtx_vector_index_unregister_tuple(index, old_tuple);
		*result = old_tuple;
		return 0;
	}

	struct vector_id_reservation reservation;
	if (memtx_vector_index_reserve_id(index, &reservation) != 0) {
		free(new_vector);
		return -1;
	}
	if (memtx_vector_index_add(index, &reservation, new_tuple,
				   new_vector) != 0) {
		memtx_vector_index_release_id(index, &reservation);
		free(new_vector);
		return -1;
	}

	if (old_tuple != NULL) {
		if (memtx_vector_index_remove_by_id(index, old_id) != 0) {
			if (memtx_vector_index_remove_by_id(index,
							    reservation.id) ==
			    0) {
				memtx_vector_index_unregister_tuple(index,
								 new_tuple);
			}
			free(new_vector);
			return -1;
		}
		memtx_vector_index_unregister_tuple(index, old_tuple);
	}

	free(new_vector);
	*result = old_tuple;
	return 0;
}

static int
memtx_vector_index_reserve(struct index *base, uint32_t size_hint)
{
	struct memtx_vector_index *index = (struct memtx_vector_index *)base;
	size_t target = MAX((size_t)size_hint, index->index.capacity());
	if (target == 0)
		target = 1;
	usearch_index_limits_t limits(target, 1);
	if (!index->index.try_reserve(limits)) {
		diag_set(OutOfMemory, 0, "usearch", "reserve");
		return -1;
	}
	return 0;
}

static struct iterator *
memtx_vector_index_create_iterator(struct index *base, enum iterator_type type,
				   const char *key, uint32_t part_count,
				   const char *pos)
{
	struct memtx_vector_index *index = (struct memtx_vector_index *)base;
	struct memtx_engine *memtx = (struct memtx_engine *)base->engine;

	if (pos != NULL) {
		diag_set(UnsupportedIndexFeature, base->def, "pagination");
		return NULL;
	}

	struct vector_index_iterator *it = (struct vector_index_iterator *)
		mempool_alloc(&memtx->iterator_pool);
	if (it == NULL) {
		diag_set(OutOfMemory, sizeof(*it), "memtx_vector_index",
			 "iterator");
		return NULL;
	}
	memset(it, 0, sizeof(*it));
	iterator_create(&it->base, base);
	it->pool = &memtx->iterator_pool;
	it->base.next_internal = vector_index_iterator_next_internal;
	it->base.next = memtx_iterator_next;
	it->base.position = generic_iterator_position;
	it->base.free = vector_index_iterator_free;

	if (type == ITER_ALL) {
		it->type = VECTOR_ITERATOR_ALL;
		if (vector_index_iterator_build_all(it, index) != 0) {
			iterator_delete(&it->base);
			return NULL;
		}
		return &it->base;
	}

	assert(type == ITER_NEIGHBOR);
	assert(part_count == 1);

	it->type = VECTOR_ITERATOR_NEIGHBOR;
	it->query = memtx_vector_alloc(index->dimension, "vector query");
	if (it->query == NULL) {
		iterator_delete(&it->base);
		return NULL;
	}
	if (memtx_vector_decode_array(it->query, index->dimension, key,
				      "key") != 0) {
		iterator_delete(&it->base);
		return NULL;
	}
	return &it->base;
}

static const struct index_vtab memtx_vector_index_vtab_base = {
	/* .destroy = */ memtx_vector_index_destroy,
	/* .commit_create = */ generic_index_commit_create,
	/* .abort_create = */ generic_index_abort_create,
	/* .commit_modify = */ generic_index_commit_modify,
	/* .commit_drop = */ generic_index_commit_drop,
	/* .update_def = */ memtx_vector_index_update_def,
	/* .depends_on_pk = */ generic_index_depends_on_pk,
	/* .def_change_requires_rebuild = */
		memtx_vector_index_def_change_requires_rebuild,
	/* .size = */ memtx_vector_index_size,
	/* .bsize = */ memtx_vector_index_bsize,
	/* .quantile = */ generic_index_quantile,
	/* .min = */ generic_index_min,
	/* .max = */ generic_index_max,
	/* .random = */ generic_index_random,
	/* .count = */ memtx_vector_index_count,
	/* .get_internal = */ generic_index_get_internal,
	/* .get = */ generic_index_get,
	/* .create_iterator = */ memtx_vector_index_create_iterator,
	/* .create_iterator_with_offset = */
		generic_index_create_iterator_with_offset,
	/* .create_arrow_stream = */ generic_index_create_arrow_stream,
	/* .create_read_view = */ generic_index_create_read_view,
	/* .stat = */ generic_index_stat,
	/* .compact = */ generic_index_compact,
	/* .reset_stat = */ generic_index_reset_stat,
};

static const struct memtx_index_vtab memtx_vector_index_vtab = {
	/* .base = */ memtx_vector_index_vtab_base,
	/* .replace = */ memtx_vector_index_replace,
	/* .begin_build = */ generic_memtx_index_begin_build,
	/* .reserve = */ memtx_vector_index_reserve,
	/* .build_next = */ generic_memtx_index_build_next,
	/* .end_build = */ generic_memtx_index_end_build,
};

struct index *
memtx_vector_index_new(struct memtx_engine *memtx, struct index_def *def)
{
	assert(def->iid > 0);
	assert(def->key_def->part_count == 1);
	assert(def->key_def->parts[0].type == FIELD_TYPE_ARRAY);
	assert(def->opts.is_unique == false);

	struct memtx_vector_index *index =
		new (std::nothrow) memtx_vector_index();
	if (index == NULL) {
		diag_set(OutOfMemory, sizeof(*index), "new",
			 "memtx_vector_index");
		return NULL;
	}
	index_create(&index->base, (struct engine *)memtx,
		     (struct index_vtab *)&memtx_vector_index_vtab, def);
	index->dimension = (uint32_t)def->opts.dimension;
	index->spare_id = SPARE_ID_END;
	matras_create(&index->id_to_tuple, sizeof(struct tuple *),
		      &memtx->index_extent_allocator,
		      &memtx->index_extent_stats);
	index->tuple_to_id = mh_vector_index_new();

	auto result = usearch_index_t::make(memtx_vector_index_make_metric(def),
					    memtx_vector_index_make_config(def));
	if (!result) {
		memtx_vector_index_diag_set_usearch_error("create",
							  result.error.what());
		index_delete(&index->base);
		return NULL;
	}
	index->index = std::move(result.index);
	if (memtx_vector_index_reserve(&index->base, 1) != 0) {
		index_delete(&index->base);
		return NULL;
	}
	return &index->base;
}
