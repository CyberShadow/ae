module ae.utils.aa_test;

package(ae):

import ae.utils.array;

version(ae_unittest) unittest
{
	int[int] aa;
	aa.update(1,
		() => 2,
		(ref int val) { return val; }
	);
}
