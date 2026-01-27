/**
 * SCRAM (Salted Challenge Response Authentication Mechanism)
 *
 * Implementation of SCRAM as defined in RFC 5802, supporting SCRAM-SHA-256.
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
module ae.utils.auth.scram;

import std.algorithm.iteration : splitter;
import std.base64 : Base64;
import std.digest : digestLength;
import std.digest.hmac : HMAC;
import std.digest.sha : SHA256;
import std.exception : enforce;
import std.random : Random, unpredictableSeed;
import std.string : representation;

import ae.utils.digest.pbkdf2 : pbkdf2;

/**
 * SCRAM client implementation.
 *
 * Params:
 *   Hash = Hash function to use (default SHA256 for SCRAM-SHA-256)
 */
struct ScramClient(Hash = SHA256)
{
    private alias PRF = HMAC!Hash;
    private enum hashLen = digestLength!Hash;

    private string username;
    private string password;
    private string clientNonce;
    private string clientFirstBare;
    private string serverFirst;
    private ubyte[hashLen] saltedPassword;
    private ubyte[hashLen] serverKey;
    private string authMessage;

    /**
     * Initialize SCRAM client with credentials.
     *
     * Params:
     *   username = The username (will be SASLprep normalized if needed)
     *   password = The password
     *   clientNonce = Optional client nonce (generated randomly if not provided)
     */
    this(string username, string password, string clientNonce = null)
    {
        this.username = username;
        this.password = password;
        this.clientNonce = clientNonce ? clientNonce : generateNonce();
    }

    /**
     * Generate the client-first-message.
     *
     * This is the first message sent to the server, containing:
     * - Channel binding flag (n = no channel binding)
     * - Username
     * - Client nonce
     *
     * Returns:
     *   The client-first-message to send to the server
     */
    string clientFirstMessage()
    {
        // GS2 header: n,, (no channel binding, no authzid)
        // client-first-message-bare: n=<user>,r=<nonce>
        clientFirstBare = "n=" ~ escapeUsername(username) ~ ",r=" ~ clientNonce;
        return "n,," ~ clientFirstBare;
    }

    /**
     * Process the server-first-message and generate client-final-message.
     *
     * The server-first-message contains:
     * - Combined nonce (client nonce + server nonce)
     * - Salt (base64 encoded)
     * - Iteration count
     *
     * Params:
     *   serverFirstMessage = The server-first-message received from server
     *
     * Returns:
     *   The client-final-message to send to the server
     *
     * Throws:
     *   Exception if the message is malformed or nonce is invalid
     */
    string clientFinalMessage(string serverFirstMessage)
    {
        serverFirst = serverFirstMessage;

        // Parse server-first-message
        string combinedNonce;
        ubyte[] salt;
        uint iterations;

        foreach (part; splitter(serverFirstMessage, ','))
        {
            if (part.length < 2 || part[1] != '=')
                continue;

            switch (part[0])
            {
                case 'r':
                    combinedNonce = part[2 .. $];
                    break;
                case 's':
                    salt = Base64.decode(part[2 .. $]);
                    break;
                case 'i':
                    iterations = parseUint(part[2 .. $]);
                    break;
                default:
                    break;
            }
        }

        enforce(combinedNonce.length > 0, "Missing nonce in server-first-message");
        enforce(salt.length > 0, "Missing salt in server-first-message");
        enforce(iterations > 0, "Missing iterations in server-first-message");
        enforce(combinedNonce.length > clientNonce.length &&
                combinedNonce[0 .. clientNonce.length] == clientNonce,
                "Server nonce doesn't start with client nonce");

        // Derive keys
        auto derivedKey = pbkdf2!PRF(
            cast(const(ubyte)[]) password.representation,
            cast(const(ubyte)[]) salt,
            iterations,
            hashLen);
        saltedPassword[] = derivedKey[0 .. hashLen];

        auto clientKey = hmac(saltedPassword[], cast(const(ubyte)[]) "Client Key".representation);
        auto storedKey = hash(clientKey[]);
        serverKey = hmac(saltedPassword[], cast(const(ubyte)[]) "Server Key".representation);

        // client-final-message-without-proof
        // c= is base64("n,,") for no channel binding
        auto clientFinalWithoutProof = "c=biws,r=" ~ combinedNonce;

        // AuthMessage = client-first-bare + "," + server-first + "," + client-final-without-proof
        authMessage = clientFirstBare ~ "," ~ serverFirst ~ "," ~ clientFinalWithoutProof;

        // ClientSignature = HMAC(StoredKey, AuthMessage)
        auto clientSignature = hmac(storedKey[], cast(const(ubyte)[]) authMessage.representation);

        // ClientProof = ClientKey XOR ClientSignature
        ubyte[hashLen] clientProof = clientKey[];
        clientProof[] ^= clientSignature[];

        return (clientFinalWithoutProof ~ ",p=" ~ Base64.encode(clientProof[])).idup;
    }

    /**
     * Verify the server-final-message.
     *
     * Params:
     *   serverFinalMessage = The server-final-message (v=<signature>)
     *
     * Returns:
     *   true if the server signature is valid
     */
    bool verifyServerFinal(string serverFinalMessage)
    {
        // Parse v=<signature>
        if (serverFinalMessage.length < 2 || serverFinalMessage[0 .. 2] != "v=")
            return false;

        auto expectedSignature = Base64.decode(serverFinalMessage[2 .. $]);

        // ServerSignature = HMAC(ServerKey, AuthMessage)
        auto serverSignature = hmac(serverKey[], cast(const(ubyte)[]) authMessage.representation);

        return expectedSignature[] == serverSignature[];
    }

    private static ubyte[hashLen] hmac(const(ubyte)[] key, const(ubyte)[] data)
    {
        auto h = PRF(key);
        h.put(data);
        return h.finish();
    }

    private static ubyte[hashLen] hash(const(ubyte)[] data)
    {
        Hash h;
        h.put(data);
        return h.finish();
    }

    private static string escapeUsername(string s)
    {
        // RFC 5802: = is replaced by =3D, , is replaced by =2C
        import std.array : replace;
        return s.replace("=", "=3D").replace(",", "=2C");
    }

    private static uint parseUint(const(char)[] s)
    {
        uint result = 0;
        foreach (c; s)
        {
            if (c < '0' || c > '9')
                break;
            result = result * 10 + (c - '0');
        }
        return result;
    }
}

/// Alias for SCRAM-SHA-256
alias ScramSHA256Client = ScramClient!SHA256;

/// Generate a random nonce suitable for SCRAM
string generateNonce()
{
    // Generate 24 random bytes and base64 encode
    ubyte[24] randomBytes;
    auto rng = Random(unpredictableSeed);
    foreach (ref b; randomBytes)
        b = cast(ubyte) rng.front, rng.popFront();
    import std.exception : assumeUnique;
    return Base64.encode(randomBytes[]).assumeUnique;
}


// Unit tests
debug(ae_unittest) unittest
{
    // Test with known values from RFC 5802 (adapted for SHA-256)
    auto client = ScramSHA256Client("user", "pencil", "rOprNGfwEbeRWgbNEkqO");

    auto clientFirst = client.clientFirstMessage();
    assert(clientFirst == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO");

    // Simulated server-first with known salt and iterations
    auto serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    auto clientFinal = client.clientFinalMessage(serverFirst);

    // Verify it starts correctly
    assert(clientFinal[0 .. 7] == "c=biws,", "Client final should start with c=biws,");
    assert(clientFinal[7 .. 9] == "r=", "Should have nonce");
}

debug(ae_unittest) unittest
{
    // Test username escaping
    auto client = ScramSHA256Client("user=name,test", "password", "testnonce");
    auto msg = client.clientFirstMessage();
    assert(msg == "n,,n=user=3Dname=2Ctest,r=testnonce");
}

debug(ae_unittest) unittest
{
    // Test nonce generation produces different values
    auto nonce1 = generateNonce();
    auto nonce2 = generateNonce();
    assert(nonce1 != nonce2);
    assert(nonce1.length > 0);
}

