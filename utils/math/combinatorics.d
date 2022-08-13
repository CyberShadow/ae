/**
 * ae.utils.math.combinatorics
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.utils.math.combinatorics;

/// https://en.wikipedia.org/wiki/Binomial_coefficient
/// This implementation is non-recursive but overflows easily
R binomialCoefficient(T, R=T)(T n, T k)
{
	if (n < k)
		return R(0);
	R result = 1;
	foreach (i; n - k + 1 .. n + 1)
		result *= i;
	foreach (i; 1 .. k + 1)
		result /= i;
	return result;
}

unittest
{
	assert(binomialCoefficient(3067L, 3) == 4803581405);
}

unittest
{
	import std.bigint : BigInt;
	assert(binomialCoefficient!(int, BigInt)(3067, 3) == 4803581405);
}

/// https://en.wikipedia.org/wiki/Multiset#Counting_multisets
R multisetCoefficient(T, R=T)(T n, T k)
{
	return binomialCoefficient!(T, R)(n + k - 1, k);
}

unittest
{
	assert(multisetCoefficient(3067L, 3) == 4812987894);
}

/// Precalculated binomial coefficient table
struct BinomialCoefficientTable(T, T maxN, T maxK)
{
	static assert(maxN >= 1);
	static assert(maxK >= 1);

	T[maxK + 1][maxN + 1] table;

	static typeof(this) generate()
	{
		typeof(this) result;
		result.table[0][0] = 1;
		foreach (n; 1 .. maxN + 1)
		{
			result.table[n][0] = 1;
			foreach (k; 1 .. maxK + 1)
				result.table[n][k] = result.table[n-1][k-1] + result.table[n-1][k];
		}
		return result;
	}

	T binomialCoefficient(T n, T k) const
	{
		return table[n][k];
	}

	T multisetCoefficient(T n, T k) const
	{
		return binomialCoefficient(n + k - 1, k);
	}
}

unittest
{
	assert(BinomialCoefficientTable!(ulong, 5000, 3).generate().binomialCoefficient(3067, 3) == 4803581405);
}

/// Combinatorial number system encoder/decoder
/// https://en.wikipedia.org/wiki/Combinatorial_number_system
struct CNS(
	/// Type for packed representation
	P,
	/// Type for one position in unpacked representation
	U,
	/// Number of positions in unpacked representation
	size_t N,
	/// Cardinality (maximum value plus one) of one position in unpacked representation
	U unpackedCard,
	/// Produce lexicographic ordering?
	bool lexicographic,
	/// Are repetitions representable? (multiset support)
	bool multiset,
	/// Binomial coefficient calculator implementation
	/// (You can supply a precalculated BinomialCoefficientTable here)
	alias binomialCalculator = ae.utils.math.combinatorics,
)
{
static:
	/// Cardinality (maximum value plus one) of the packed representation
	static if (multiset)
		enum P packedCard = multisetCoefficient(unpackedCard, N);
	else
		enum P packedCard = binomialCoefficient(unpackedCard, N);
	alias Index = P;

	private P summand(U value, Index i)
	{
		static if (lexicographic)
		{
			value = cast(U)(unpackedCard-1 - value);
			i = cast(Index)(N-1 - i);
		}
		static if (multiset)
			value += i;
		return binomialCalculator.binomialCoefficient(value, i + 1);
	}

	P pack(U[N] values)
	{
		P packed = 0;
		foreach (Index i, value; values)
		{
			static if (!multiset)
				assert(i == 0 || value > values[i-1]);
			else
				assert(i == 0 || value >= values[i-1]);

			packed += summand(value, i);
		}

		static if (lexicographic)
			packed = packedCard-1 - packed;
		return packed;
	}

	U[N] unpack(P packed)
	{
		static if (lexicographic)
			packed = packedCard-1 - packed;

		void unpackOne(Index i, ref U r)
		{
			static if (lexicographic)
				enum lastValue = 0;
			else
				enum lastValue = unpackedCard - 1;

			bool checkValue(U value, U nextValue)
			{
				if (value == lastValue || summand(nextValue, i) > packed)
				{
					r = value;
					packed -= summand(value, i);
					return true;
				}
				return false;
			}

			// TODO optimize: rolling product or binary search?
			// TODO optimize: don't check below N-i
			static if (lexicographic)
			{
				foreach_reverse (U value; 0 .. unpackedCard)
					if (checkValue(value, cast(U)(value - 1)))
						break;
			}
			else
			{
				foreach         (U value; 0 .. unpackedCard)
					if (checkValue(value, cast(U)(value + 1)))
						break;
			}
		}

		U[N] values;
		static if (lexicographic)
			foreach         (Index i, ref r; values)
				unpackOne(i, r);
		else
			foreach_reverse (Index i, ref r; values)
				unpackOne(i, r);

		return values;
	}
}

unittest
{
	enum N = 3;
	enum cardinality = 10;

	static foreach (lexicographic; [false, true])
	static foreach (multiset; [false, true])
	static foreach (precalculate; [false, true])
	{{
		static if (precalculate)
			static immutable calculator = BinomialCoefficientTable!(uint, cardinality + 1, N).generate();
		else
			alias calculator = ae.utils.math.combinatorics;
		alias testCNS = CNS!(uint, ubyte, N, cardinality, lexicographic, multiset, calculator);

		uint counter;
		foreach (ubyte a; 0 .. cardinality)
		foreach (ubyte b; cast(ubyte)(a + (multiset ? 0 : 1)) .. cardinality)
		foreach (ubyte c; cast(ubyte)(b + (multiset ? 0 : 1)) .. cardinality)
		{
			ubyte[N] input = [a, b, c];
			auto packed = testCNS.pack(input);
			assert(packed < testCNS.packedCard);
			static if (lexicographic)
				assert(counter == packed, "Packed is wrong");
			auto unpacked = testCNS.unpack(packed);
			assert(input == unpacked, "Unpacked is wrong");
			counter++;
		}
	}}
}
