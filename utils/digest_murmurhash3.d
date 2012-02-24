//-----------------------------------------------------------------------------
// MurmurHash3 was written by Austin Appleby, and is placed in the public
// domain. The author hereby disclaims copyright to this source code.


// Note - The x86 and x64 versions do _not_ produce the same results, as the
// algorithms are optimized for their respective platforms. You can still
// compile and run any of them on any platform, but your performance with the
// non-native version will be less than optimal.


module ae.utils.digest_murmurhash3;

private:

import ae.utils.meta;

alias byte  int8_t;
alias ubyte uint8_t;
alias uint  uint32_t;
alias ulong uint64_t;

//-----------------------------------------------------------------------------
// Platform-specific functions and macros

/*inline*/ uint32_t rotl32(int r) ( uint32_t x )
{
	return (x << r) | (x >> (32 - r));
}


/*inline*/ uint64_t rotl64(int r) ( uint64_t x )
{
	return (x << r) | (x >> (64 - r));
}

//-----------------------------------------------------------------------------
// Block read - if your platform needs to do endian-swapping or can only
// handle aligned reads, do the conversion here

/+
/*FORCE_INLINE*/ uint32_t getblock ( const uint32_t * p, int i )
{
	return p[i];
}


/*FORCE_INLINE*/ uint64_t getblock ( const uint64_t * p, int i )
{
	return p[i];
}
+/

string GETBLOCK(string P, string I)
{
	return mixin(X!q{ @(P) [ @(I) ] });
}

//-----------------------------------------------------------------------------
// Finalization mix - force all bits of a hash block to avalanche

/+
/*FORCE_INLINE*/ uint32_t fmix ( uint32_t h )
{
	h ^= h >> 16;
	h *= 0x85ebca6b;
	h ^= h >> 13;
	h *= 0xc2b2ae35;
	h ^= h >> 16;


	return h;
}


//----------


/*FORCE_INLINE*/ uint64_t fmix ( uint64_t k )
{
	k ^= k >> 33;
	k *= BIG_CONSTANT(0xff51afd7ed558ccd);
	k ^= k >> 33;
	k *= BIG_CONSTANT(0xc4ceb9fe1a85ec53);
	k ^= k >> 33;


	return k;
}
+/

string FMIX_32(string H)
{
	return mixin(X!q{
		@(H) ^= @(H) >> 16;
		@(H) *= 0x85ebca6b;
		@(H) ^= @(H) >> 13;
		@(H) *= 0xc2b2ae35;
		@(H) ^= @(H) >> 16;
	});
}

string FMIX_64(string H)
{
	return mixin(X!q{
		@(H) ^= @(H) >> 33;
		@(H) *= 0xff51afd7ed558ccdL;
		@(H) ^= @(H) >> 33;
		@(H) *= 0xc4ceb9fe1a85ec53L;
		@(H) ^= @(H) >> 33;
	});
}


//-----------------------------------------------------------------------------

public:

void MurmurHash3_x86_32 ( const void * key, int len, uint32_t seed, void * output )
{
	const uint8_t * data = cast(const uint8_t*)key;
	const int nblocks = len / 4;


	uint32_t h1 = seed;


	uint32_t c1 = 0xcc9e2d51;
	uint32_t c2 = 0x1b873593;


	//----------
	// body


	const uint32_t * blocks = cast(const uint32_t *)(data + nblocks*4);


	for(int i = -nblocks; i; i++)
	{
		uint32_t k1 = mixin(GETBLOCK(q{blocks},q{i}));


		k1 *= c1;
		k1 = rotl32!15(k1);
		k1 *= c2;

		h1 ^= k1;
		h1 = rotl32!13(h1);
		h1 = h1*5+0xe6546b64;
	}


	//----------
	// tail


	const uint8_t * tail = cast(const uint8_t*)(data + nblocks*4);


	uint32_t k1 = 0;


	switch(len & 3)
	{
	case 3: k1 ^= tail[2] << 16;                              goto case;
	case 2: k1 ^= tail[1] << 8;                               goto case;
	case 1: k1 ^= tail[0];
	        k1 *= c1; k1 = rotl32!15(k1); k1 *= c2; h1 ^= k1; break;
	default:
	}


	//----------
	// finalization


	h1 ^= len;


	mixin(FMIX_32(q{h1}));


	*cast(uint32_t*)output = h1;
}

//-----------------------------------------------------------------------------


void MurmurHash3_x86_128 ( const void * key, const int len, uint32_t seed, void * output )
{
	const uint8_t * data = cast(const uint8_t*)key;
	const int nblocks = len / 16;


	uint32_t h1 = seed;
	uint32_t h2 = seed;
	uint32_t h3 = seed;
	uint32_t h4 = seed;


	uint32_t c1 = 0x239b961b;
	uint32_t c2 = 0xab0e9789;
	uint32_t c3 = 0x38b34ae5;
	uint32_t c4 = 0xa1e38b93;


	//----------
	// body


	const uint32_t * blocks = cast(const uint32_t *)(data + nblocks*16);


	for(int i = -nblocks; i; i++)
	{
		uint32_t k1 = mixin(GETBLOCK(q{blocks},q{i*4+0}));
		uint32_t k2 = mixin(GETBLOCK(q{blocks},q{i*4+1}));
		uint32_t k3 = mixin(GETBLOCK(q{blocks},q{i*4+2}));
		uint32_t k4 = mixin(GETBLOCK(q{blocks},q{i*4+3}));


		k1 *= c1; k1  = rotl32!15(k1); k1 *= c2; h1 ^= k1;


		h1 = rotl32!19(h1); h1 += h2; h1 = h1*5+0x561ccd1b;


		k2 *= c2; k2  = rotl32!16(k2); k2 *= c3; h2 ^= k2;


		h2 = rotl32!17(h2); h2 += h3; h2 = h2*5+0x0bcaa747;


		k3 *= c3; k3  = rotl32!17(k3); k3 *= c4; h3 ^= k3;


		h3 = rotl32!15(h3); h3 += h4; h3 = h3*5+0x96cd1c35;


		k4 *= c4; k4  = rotl32!18(k4); k4 *= c1; h4 ^= k4;


		h4 = rotl32!13(h4); h4 += h1; h4 = h4*5+0x32ac3b17;
	}


	//----------
	// tail


	const uint8_t * tail = cast(const uint8_t*)(data + nblocks*16);


	uint32_t k1 = 0;
	uint32_t k2 = 0;
	uint32_t k3 = 0;
	uint32_t k4 = 0;


	switch(len & 15)
	{
	case 15: k4 ^= tail[14] << 16;                              goto case;
	case 14: k4 ^= tail[13] << 8;                               goto case;
	case 13: k4 ^= tail[12] << 0;
	         k4 *= c4; k4  = rotl32!18(k4); k4 *= c1; h4 ^= k4; goto case;


	case 12: k3 ^= tail[11] << 24;                              goto case;
	case 11: k3 ^= tail[10] << 16;                              goto case;
	case 10: k3 ^= tail[ 9] << 8;                               goto case;
	case  9: k3 ^= tail[ 8] << 0;
	         k3 *= c3; k3  = rotl32!17(k3); k3 *= c4; h3 ^= k3; goto case;


	case  8: k2 ^= tail[ 7] << 24;                              goto case;
	case  7: k2 ^= tail[ 6] << 16;                              goto case;
	case  6: k2 ^= tail[ 5] << 8;                               goto case;
	case  5: k2 ^= tail[ 4] << 0;
	         k2 *= c2; k2  = rotl32!16(k2); k2 *= c3; h2 ^= k2; goto case;


	case  4: k1 ^= tail[ 3] << 24;                              goto case;
	case  3: k1 ^= tail[ 2] << 16;                              goto case;
	case  2: k1 ^= tail[ 1] << 8;                               goto case;
	case  1: k1 ^= tail[ 0] << 0;
	         k1 *= c1; k1  = rotl32!15(k1); k1 *= c2; h1 ^= k1; goto default;
	default:
	}


	//----------
	// finalization


	h1 ^= len; h2 ^= len; h3 ^= len; h4 ^= len;


	h1 += h2; h1 += h3; h1 += h4;
	h2 += h1; h3 += h1; h4 += h1;


	mixin(FMIX_32(q{h1}));
	mixin(FMIX_32(q{h2}));
	mixin(FMIX_32(q{h3}));
	mixin(FMIX_32(q{h4}));


	h1 += h2; h1 += h3; h1 += h4;
	h2 += h1; h3 += h1; h4 += h1;


	(cast(uint32_t*)output)[0] = h1;
	(cast(uint32_t*)output)[1] = h2;
	(cast(uint32_t*)output)[2] = h3;
	(cast(uint32_t*)output)[3] = h4;
}


//-----------------------------------------------------------------------------

void MurmurHash3_x64_128 ( const void * key, const int len, const uint32_t seed, void * output )
{
	const uint8_t * data = cast(const uint8_t*)key;
	const int nblocks = len / 16;


	uint64_t h1 = seed;
	uint64_t h2 = seed;


	uint64_t c1 = 0x87c37b91114253d5L;
	uint64_t c2 = 0x4cf5ad432745937fL;


	//----------
	// body


	const uint64_t * blocks = cast(const uint64_t *)(data);


	for(int i = 0; i < nblocks; i++)
	{
		uint64_t k1 = mixin(GETBLOCK(q{blocks},q{i*2+0}));
		uint64_t k2 = mixin(GETBLOCK(q{blocks},q{i*2+1}));


		k1 *= c1; k1  = rotl64!31(k1); k1 *= c2; h1 ^= k1;


		h1 = rotl64!27(h1); h1 += h2; h1 = h1*5+0x52dce729;


		k2 *= c2; k2  = rotl64!33(k2); k2 *= c1; h2 ^= k2;


		h2 = rotl64!31(h2); h2 += h1; h2 = h2*5+0x38495ab5;
	}


	//----------
	// tail


	const uint8_t * tail = cast(const uint8_t*)(data + nblocks*16);


	uint64_t k1 = 0;
	uint64_t k2 = 0;


	switch(len & 15)
	{
	case 15: k2 ^= cast(uint64_t)(tail[14]) << 48;              goto case;
	case 14: k2 ^= cast(uint64_t)(tail[13]) << 40;              goto case;
	case 13: k2 ^= cast(uint64_t)(tail[12]) << 32;              goto case;
	case 12: k2 ^= cast(uint64_t)(tail[11]) << 24;              goto case;
	case 11: k2 ^= cast(uint64_t)(tail[10]) << 16;              goto case;
	case 10: k2 ^= cast(uint64_t)(tail[ 9]) << 8;               goto case;
	case  9: k2 ^= cast(uint64_t)(tail[ 8]) << 0;
	         k2 *= c2; k2  = rotl64!33(k2); k2 *= c1; h2 ^= k2; goto case;


	case  8: k1 ^= cast(uint64_t)(tail[ 7]) << 56;              goto case;
	case  7: k1 ^= cast(uint64_t)(tail[ 6]) << 48;              goto case;
	case  6: k1 ^= cast(uint64_t)(tail[ 5]) << 40;              goto case;
	case  5: k1 ^= cast(uint64_t)(tail[ 4]) << 32;              goto case;
	case  4: k1 ^= cast(uint64_t)(tail[ 3]) << 24;              goto case;
	case  3: k1 ^= cast(uint64_t)(tail[ 2]) << 16;              goto case;
	case  2: k1 ^= cast(uint64_t)(tail[ 1]) << 8;               goto case;
	case  1: k1 ^= cast(uint64_t)(tail[ 0]) << 0;
	         k1 *= c1; k1  = rotl64!31(k1); k1 *= c2; h1 ^= k1; goto default;
	default:
	}


	//----------
	// finalization


	h1 ^= len; h2 ^= len;


	h1 += h2;
	h2 += h1;


	mixin(FMIX_64(q{h1}));
	mixin(FMIX_64(q{h2}));


	h1 += h2;
	h2 += h1;


	(cast(uint64_t*)output)[0] = h1;
	(cast(uint64_t*)output)[1] = h2;
}


//-----------------------------------------------------------------------------
