/**
 * PBKDF2 (Password-Based Key Derivation Function 2)
 *
 * Implementation of PBKDF2 as defined in RFC 2898 / RFC 8018.
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
module ae.utils.digest.pbkdf2;

import std.algorithm.comparison : min;
import std.bitmanip : nativeToBigEndian;
import std.digest : digestLength;
import std.digest.hmac : HMAC;
import std.digest.sha : SHA256;

/**
 * PBKDF2 key derivation function.
 *
 * Params:
 *   PRF = Pseudo-random function (HMAC instantiation), default HMAC!SHA256
 *   password = The password to derive from
 *   salt = Salt value
 *   iterations = Number of iterations (c)
 *   dkLen = Desired length of derived key in bytes
 *
 * Returns:
 *   Derived key of length dkLen
 */
ubyte[] pbkdf2(PRF = HMAC!SHA256)(
    const(ubyte)[] password,
    const(ubyte)[] salt,
    uint iterations,
    size_t dkLen = digestLength!PRF)
{
    enum hLen = digestLength!PRF;
    auto result = new ubyte[dkLen];

    // T_i = F(Password, Salt, c, i)
    // DK = T_1 || T_2 || ... || T_dklen/hlen
    uint blockNum = 1;
    size_t offset = 0;

    while (offset < dkLen)
    {
        auto block = pbkdf2Block!PRF(password, salt, iterations, blockNum);
        auto toCopy = min(hLen, dkLen - offset);
        result[offset .. offset + toCopy] = block[0 .. toCopy];
        offset += toCopy;
        blockNum++;
    }

    return result;
}

/// ditto
ubyte[] pbkdf2(PRF = HMAC!SHA256)(
    const(char)[] password,
    const(char)[] salt,
    uint iterations,
    size_t dkLen = digestLength!PRF)
{
    return pbkdf2!PRF(
        cast(const(ubyte)[]) password,
        cast(const(ubyte)[]) salt,
        iterations,
        dkLen);
}

private ubyte[digestLength!PRF] pbkdf2Block(PRF)(
    const(ubyte)[] password,
    const(ubyte)[] salt,
    uint iterations,
    uint blockNum)
{
    enum hLen = digestLength!PRF;

    ubyte[hLen] hmacCompute(const(ubyte)[] data)
    {
        auto prf = PRF(password);
        prf.put(data);
        return prf.finish();
    }

    // U_1 = PRF(Password, Salt || INT(i))
    ubyte[] saltWithBlock = salt ~ nativeToBigEndian(blockNum)[];
    ubyte[hLen] u = hmacCompute(saltWithBlock);
    ubyte[hLen] result = u;

    // U_2 = PRF(Password, U_1), ..., U_c = PRF(Password, U_{c-1})
    // F = U_1 ^ U_2 ^ ... ^ U_c
    foreach (_; 1 .. iterations)
    {
        u = hmacCompute(u[]);
        result[] ^= u[];
    }

    return result;
}

// Test vectors from RFC 6070
debug(ae_unittest) unittest
{
    import std.digest : toHexString, LetterCase;
    import std.digest.sha : SHA1;
    import std.digest.hmac : HMAC;

    // Test case 1
    assert(pbkdf2!(HMAC!SHA1)("password", "salt", 1, 20)
        .toHexString!(LetterCase.lower) == "0c60c80f961f0e71f3a9b524af6012062fe037a6");

    // Test case 2
    assert(pbkdf2!(HMAC!SHA1)("password", "salt", 2, 20)
        .toHexString!(LetterCase.lower) == "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957");

    // Test case 3
    assert(pbkdf2!(HMAC!SHA1)("password", "salt", 4096, 20)
        .toHexString!(LetterCase.lower) == "4b007901b765489abead49d926f721d065a429c1");

    // Test case 5 (longer output)
    assert(pbkdf2!(HMAC!SHA1)("passwordPASSWORDpassword", "saltSALTsaltSALTsaltSALTsaltSALTsalt", 4096, 25)
        .toHexString!(LetterCase.lower) == "3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038");
}

// SHA-256 test
debug(ae_unittest) unittest
{
    import std.digest : toHexString, LetterCase;

    // PBKDF2-HMAC-SHA256 test vector
    // From https://stackoverflow.com/questions/5130513/pbkdf2-hmac-sha2-test-vectors
    assert(pbkdf2!(HMAC!SHA256)("password", "salt", 1, 32)
        .toHexString!(LetterCase.lower) == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b");

    assert(pbkdf2!(HMAC!SHA256)("password", "salt", 4096, 32)
        .toHexString!(LetterCase.lower) == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a");
}
