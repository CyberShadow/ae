/**
 * SChannel (Windows) SSL backend.
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

module ae.net.ssl.schannel;

version (Windows):

import core.sys.windows.windows;
import core.sys.windows.schannel;
import core.sys.windows.security;
import core.sys.windows.sspi;
import core.sys.windows.wincrypt;
import core.sys.windows.ntsecpkg :
    ISC_REQ_REPLAY_DETECT, ISC_REQ_SEQUENCE_DETECT, ISC_REQ_CONFIDENTIALITY,
    ISC_REQ_ALLOCATE_MEMORY, ISC_REQ_EXTENDED_ERROR, ISC_REQ_STREAM,
    ISC_REQ_USE_SUPPLIED_CREDS, ISC_REQ_MANUAL_CRED_VALIDATION,
    ASC_REQ_REPLAY_DETECT, ASC_REQ_SEQUENCE_DETECT, ASC_REQ_CONFIDENTIALITY,
    ASC_REQ_ALLOCATE_MEMORY, ASC_REQ_EXTENDED_ERROR, ASC_REQ_STREAM,
    ASC_REQ_MUTUAL_AUTH;

import std.algorithm.comparison : min;
import std.conv : to;
import std.string : fromStringz;
import std.utf : toUTF16z, toUTF8;

import ae.net.asockets;
import ae.net.ssl;
import ae.utils.array : nonNull;
import ae.utils.exception : CaughtException;
import ae.utils.meta : enumLength;

debug(SCHANNEL) import std.stdio : stderr;
debug(SCHANNEL_DATA) import std.stdio : stderr;

pragma(lib, "secur32");
pragma(lib, "crypt32");
pragma(lib, "ncrypt");

// =============================================================================
// Bindings supplement — symbols missing from druntime's
// core.sys.windows.{schannel,sspi,wincrypt} as of druntime 2.111 / LDC 1.41.
// See .cydo/tasks/17792/druntime-bug-missing-schannel-bindings.md and
// druntime-bug-applycontroltoken.md.
// =============================================================================

private:

// TLS 1.1 / 1.2 / 1.3 protocol bits — druntime only defines SP_PROT_TLS1_* (TLS 1.0).
enum DWORD
    SP_PROT_TLS1_1_SERVER = 0x0100,
    SP_PROT_TLS1_1_CLIENT = 0x0200,
    SP_PROT_TLS1_1        = SP_PROT_TLS1_1_SERVER | SP_PROT_TLS1_1_CLIENT,
    SP_PROT_TLS1_2_SERVER = 0x0400,
    SP_PROT_TLS1_2_CLIENT = 0x0800,
    SP_PROT_TLS1_2        = SP_PROT_TLS1_2_SERVER | SP_PROT_TLS1_2_CLIENT,
    SP_PROT_TLS1_3_SERVER = 0x1000,
    SP_PROT_TLS1_3_CLIENT = 0x2000,
    SP_PROT_TLS1_3        = SP_PROT_TLS1_3_SERVER | SP_PROT_TLS1_3_CLIENT;

// Version for the SCH_CREDENTIALS struct (distinct from SCHANNEL_CRED_VERSION = 4).
enum DWORD SCH_CREDENTIALS_VERSION = 0x5;

// UNICODE_STRING — used by TLS_PARAMETERS and CRYPTO_SETTINGS.
// Present in some druntime modules but not reachable from core.sys.windows.windows.
struct UNICODE_STRING
{
    USHORT Length;
    USHORT MaximumLength;
    PWSTR  Buffer;
}

// Modern per-suite and per-algorithm cipher control (Win10 1809+).
struct CRYPTO_SETTINGS
{
    int            eAlgorithmUsage;  // eTlsAlgorithmUsage
    UNICODE_STRING strCngAlgId;
    DWORD          cChainingModes;
    UNICODE_STRING* rgstrChainingModes;
    DWORD          dwMinBitLength;
    DWORD          dwMaxBitLength;
}
alias PCRYPTO_SETTINGS = CRYPTO_SETTINGS*;

struct TLS_PARAMETERS
{
    DWORD            cAlpnIds;
    UNICODE_STRING*  rgstrAlpnIds;
    DWORD            grbitDisabledProtocols;
    DWORD            cDisabledCrypto;
    PCRYPTO_SETTINGS pDisabledCrypto;
    DWORD            dwFlags;
}
alias PTLS_PARAMETERS = TLS_PARAMETERS*;

struct SCH_CREDENTIALS
{
    DWORD           dwVersion;
    DWORD           dwCredFormat;
    DWORD           cCreds;
    PCCERT_CONTEXT* paCred;
    HCERTSTORE      hRootStore;
    DWORD           cMappers;
    void**          aphMappers;
    DWORD           dwSessionLifespan;
    DWORD           dwFlags;
    DWORD           cTlsParameters;
    PTLS_PARAMETERS pTlsParameters;
}

// secur32.dll exports the unsuffixed `ApplyControlToken`; druntime declares
// ApplyControlTokenA/W (neither of which exists in the DLL).
// See .cydo/tasks/17792/druntime-bug-applycontroltoken.md.
extern(Windows) nothrow @nogc
    SECURITY_STATUS ApplyControlToken(PCtxtHandle, PSecBufferDesc);

// crypt32 symbols missing from druntime wincrypt.d.
extern(Windows) nothrow @nogc
{
    HCERTSTORE    PFXImportCertStore(CRYPT_DATA_BLOB*, LPCWSTR, DWORD);
    DWORD         CertGetNameStringW(PCCERT_CONTEXT, DWORD, DWORD, void*, LPWSTR, DWORD);
    PCCERT_CONTEXT CertCreateCertificateContext(DWORD, const(BYTE)*, DWORD);
    BOOL          CertAddCertificateContextToStore(HCERTSTORE, PCCERT_CONTEXT, DWORD, PCCERT_CONTEXT*);
    PCCERT_CONTEXT CertEnumCertificatesInStore(HCERTSTORE, PCCERT_CONTEXT);
    PCCERT_CONTEXT CertDuplicateCertificateContext(PCCERT_CONTEXT);
    BOOL          CertGetCertificateContextProperty(PCCERT_CONTEXT, DWORD, void*, DWORD*);
    // PEM/base64 → DER decoder (for setPeerRootCertificate PEM support).
    BOOL          CryptStringToBinaryA(const(char)*, DWORD, DWORD, BYTE*, DWORD*, DWORD*, DWORD*);
}

// CERT_KEY_PROV_INFO_PROP_ID property: stores the name of the key container
// (set by PFXImportCertStore without PKCS12_NO_PERSIST_KEY, readable by LSASS).
enum DWORD CERT_KEY_PROV_INFO_PROP_ID = 2;

// Key provider info structure returned by CertGetCertificateContextProperty for
// CERT_KEY_PROV_INFO_PROP_ID.  dwProvType == 0 ⇒ CNG key; != 0 ⇒ legacy CSP.
struct CRYPT_KEY_PROV_INFO
{
    LPWSTR pwszContainerName;
    LPWSTR pwszProvName;
    DWORD  dwProvType;
    DWORD  dwFlags;
    DWORD  cProvParam;
    void*  rgProvParam;  // PCRYPT_KEY_PROV_PARAM — unused in our cleanup path
    DWORD  dwKeySpec;
}

// ncrypt.dll bindings — used by the perphemeral PFX cleanup path.
alias ULONG_PTR NCRYPT_HANDLE;
alias NCRYPT_HANDLE NCRYPT_PROV_HANDLE;
alias NCRYPT_HANDLE NCRYPT_KEY_HANDLE;

extern(Windows) nothrow @nogc
{
    SECURITY_STATUS NCryptOpenStorageProvider(NCRYPT_PROV_HANDLE*, LPCWSTR, DWORD);
    SECURITY_STATUS NCryptOpenKey(NCRYPT_PROV_HANDLE, NCRYPT_KEY_HANDLE*, LPCWSTR, DWORD, DWORD);
    SECURITY_STATUS NCryptDeleteKey(NCRYPT_KEY_HANDLE, DWORD);  // also frees hKey on success
    SECURITY_STATUS NCryptFreeObject(NCRYPT_HANDLE);
}

enum DWORD NCRYPT_MACHINE_KEY_FLAG = 0x00000020;
enum DWORD NCRYPT_SILENT_FLAG      = 0x00000040;

// Certificate store / name string constants missing from druntime.
enum DWORD CERT_NAME_SIMPLE_DISPLAY_TYPE = 4;
enum DWORD CERT_FIND_ANY                 = 0;
enum DWORD CERT_FIND_SUBJECT_STR_W       = 0x00080007;
enum DWORD CERT_STORE_ADD_NEW            = 1;
enum DWORD CERT_STORE_ADD_REPLACE_EXISTING = 3;
enum DWORD CRYPT_STRING_BASE64HEADER     = 0;   // PEM with -----BEGIN / END----- headers
enum DWORD AUTHTYPE_CLIENT               = 1;
enum DWORD AUTHTYPE_SERVER               = 2;

// SECBUFFER_ALERT: receives TLS alert data on handshake failure.
enum ULONG SECBUFFER_ALERT = 17;

// =============================================================================

public:

/// `SSLProvider` implementation backed by Windows SChannel / SSPI.
class SChannelProvider : SSLProvider
{
    override SSLContext createContext(SSLContext.Kind kind)
    {
        return new SChannelContext(kind);
    }

    override SSLAdapter createAdapter(SSLContext context, IConnection next)
    {
        auto ctx = cast(SChannelContext) context;
        if (!ctx) assert(false, "Not an SChannelContext");
        return new SChannelAdapter(ctx, next);
    }
}

// =============================================================================

/// `SSLContext` implementation backed by Windows SChannel.
class SChannelContext : SSLContext
{
    Kind kind;
    Verify verify = Verify.verify;
    SSLVersion minVersion = SSLVersion.tls12;
    SSLVersion maxVersion = SSLVersion.unspecified;
    DWORD extraFlags;
    PCCERT_CONTEXT certContext;  // identity cert loaded by setIdentityFromPKCS12
    bool ownsKeyContainer;       // true ⇒ delete the key container when certContext is freed
    HCERTSTORE peerRootStore;    // custom root CA store for peer verification

    this(Kind kind) { this.kind = kind; }

    ~this()
    {
        if (certContext)
        {
            if (ownsKeyContainer)
                deleteKeyContainerSilent(certContext);
            CertFreeCertificateContext(certContext);
            certContext = null;
        }
        if (peerRootStore)
        {
            CertCloseStore(peerRootStore, 0);
            peerRootStore = null;
        }
    }

    // -- Cross-backend interface: cipher suites ----------------------------

    override void setCipherSuites(string[] ianaNames)
    {
        // SChannel cipher-suite control is via CRYPTO_SETTINGS (IANA name →
        // algorithm primitive mapping), which requires a full IANA-to-CNG
        // algorithm table.  That mapping is complex and not yet implemented.
        // Per plan Q6 resolution: throw rather than silently no-op, since
        // cipher selection is security-relevant.
        throw new Exception("setCipherSuites: per-suite control is not yet implemented "
            ~ "for the SChannel backend (IANA → CRYPTO_SETTINGS mapping is not trivial); "
            ~ "use setMinimumVersion/setMaximumVersion to restrict the protocol version instead");
    }

    // -- Cross-backend interface: identity ---------------------------------

    override void setCertificate(string path)
    {
        throw new Exception("setCertificate: PEM certificate loading is not supported by SChannel; "
            ~ "use setIdentityFromPKCS12(path, password) instead, or "
            ~ "setCertificateContext(PCCERT_CONTEXT) for Windows certificate store certs");
    }

    override void setPrivateKey(string path)
    {
        throw new Exception("setPrivateKey: PEM private key loading is not supported by SChannel; "
            ~ "use setIdentityFromPKCS12(path, password) instead, or "
            ~ "setCertificateContext(PCCERT_CONTEXT) for Windows certificate store certs");
    }

    override void setIdentityFromPKCS12(string path, string password)
    {
        import std.file : read;
        setIdentityFromPKCS12(cast(const(ubyte)[]) read(path), password);
    }

    /// Load identity from in-memory PFX bytes using the .NET-style "perphemeral"
    /// pattern: import with dwFlags=0 (key persists in the user CNG/CSP store),
    /// then delete the key container on teardown.  This is the only reliable path
    /// for SChannel server credentials — PKCS12_NO_PERSIST_KEY stores the key as
    /// an in-process NCRYPT_KEY_HANDLE that LSASS cannot dereference.
    /// See .cydo/tasks/17811/output.md for the full analysis.
    override void setIdentityFromPKCS12(const(ubyte)[] data, string password)
    {
        CRYPT_DATA_BLOB blob;
        blob.cbData = cast(DWORD) data.length;
        blob.pbData = cast(BYTE*) data.ptr;

        const(wchar)* pwz = password.length ? password.toUTF16z() : null;

        // dwFlags=0: key is written to the user CNG/CSP store (required for
        // LSASS-side credential acquisition in server mode).
        HCERTSTORE store = PFXImportCertStore(&blob, pwz, 0);
        sspiEnforce(store !is null, "PFXImportCertStore");
        scope(exit) CertCloseStore(store, 0);

        // Find best cert: prefer one with a private key (CERT_KEY_PROV_INFO_PROP_ID
        // present), fall back to first cert if none has a key.
        PCCERT_CONTEXT chosen = null;
        PCCERT_CONTEXT iter = null;
        bool chosenHasKey = false;
        while ((iter = CertEnumCertificatesInStore(store, iter)) !is null)
        {
            DWORD cb = 0;
            bool hasKey = CertGetCertificateContextProperty(
                iter, CERT_KEY_PROV_INFO_PROP_ID, null, &cb) != 0;

            if (hasKey && !chosenHasKey)
            {
                // Upgrade to a cert that has a key.
                if (chosen) CertFreeCertificateContext(chosen);
                chosen = CertDuplicateCertificateContext(iter);
                chosenHasKey = true;
                // CertEnumCertificatesInStore increments the refcount of the returned
                // context; caller must free it.  We break early so we free iter here
                // rather than via the next CertEnumCertificatesInStore call.
                CertFreeCertificateContext(iter);
                break;
            }
            else if (!chosen)
            {
                chosen = CertDuplicateCertificateContext(iter);
                // iter will be freed by the next CertEnumCertificatesInStore call.
            }
        }

        if (!chosen)
            throw new Exception("setIdentityFromPKCS12: PFX contains no certificates");

        // Replace any existing identity.
        if (certContext)
        {
            if (ownsKeyContainer) deleteKeyContainerSilent(certContext);
            CertFreeCertificateContext(certContext);
        }
        certContext = chosen;
        ownsKeyContainer = chosenHasKey;
    }

    // -- Cross-backend interface: peer verification -----------------------

    override void setPeerVerify(Verify v) { verify = v; }

    override void setPeerRootCertificate(string path)
    {
        import std.file : read;
        auto bytes = cast(const(ubyte)[]) read(path);

        // Try DER first.
        PCCERT_CONTEXT cert = CertCreateCertificateContext(
            X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            cast(const(BYTE)*) bytes.ptr, cast(DWORD) bytes.length);

        if (!cert)
        {
            // Fall back to PEM (base64 with -----BEGIN CERTIFICATE----- header).
            DWORD derLen = 0;
            if (CryptStringToBinaryA(cast(const(char)*) bytes.ptr, cast(DWORD) bytes.length,
                    CRYPT_STRING_BASE64HEADER, null, &derLen, null, null) && derLen)
            {
                auto der = new ubyte[derLen];
                if (CryptStringToBinaryA(cast(const(char)*) bytes.ptr, cast(DWORD) bytes.length,
                        CRYPT_STRING_BASE64HEADER, der.ptr, &derLen, null, null))
                    cert = CertCreateCertificateContext(
                        X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
                        der.ptr, derLen);
            }
        }
        sspiEnforce(cert !is null, "CertCreateCertificateContext (root cert: " ~ path ~ ")");

        if (!peerRootStore)
        {
            peerRootStore = CertOpenStore(cast(LPCSTR) 2 /* CERT_STORE_PROV_MEMORY */,
                0, cast(HCRYPTPROV) 0, 0, null);
            sspiEnforce(peerRootStore !is null, "CertOpenStore(MEMORY)");
        }
        BOOL ok = CertAddCertificateContextToStore(
            peerRootStore, cert, CERT_STORE_ADD_REPLACE_EXISTING, null);
        CertFreeCertificateContext(cert);
        sspiEnforce(ok != 0, "CertAddCertificateContextToStore");
    }

    override void setFlags(int flags) { extraFlags |= cast(DWORD) flags; }

    override void setMinimumVersion(SSLVersion v) { minVersion = v; }

    override void setMaximumVersion(SSLVersion v) { maxVersion = v; }

    // -- Extra non-portable convenience methods ----------------------------

    /// Provide an identity cert directly from a Windows cert store handle.
    /// The context's refcount is incremented; the caller retains its own reference.
    void setCertificateContext(PCCERT_CONTEXT cert)
    {
        if (certContext)
        {
            if (ownsKeyContainer) deleteKeyContainerSilent(certContext);
            CertFreeCertificateContext(certContext);
        }
        certContext = CertDuplicateCertificateContext(cert);
        ownsKeyContainer = false; // caller owns the key container lifecycle
    }

    /// Find a certificate by subject name in a named Windows certificate store.
    void setCredentialsFromSystemStore(string subjectName, string storeName = "MY")
    {
        import std.utf : toUTF16z;
        HCERTSTORE store = CertOpenSystemStoreW(cast(HCRYPTPROV) 0, storeName.toUTF16z());
        sspiEnforce(store !is null, "CertOpenSystemStoreW(\"" ~ storeName ~ "\")");
        scope(exit) CertCloseStore(store, 0);

        const(wchar)* subjW = subjectName.toUTF16z();
        PCCERT_CONTEXT cert = CertFindCertificateInStore(
            store, X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            0, CERT_FIND_SUBJECT_STR_W, cast(void*) subjW, null);
        sspiEnforce(cert !is null,
            "CertFindCertificateInStore: no cert with subject \"" ~ subjectName ~ "\" in store \"" ~ storeName ~ "\"");

        setCertificateContext(cert);
        CertFreeCertificateContext(cert); // setCertificateContext duplicated it
    }

    // -- Internal: build credentials ---------------------------------------

    package CredHandle acquireCredentials()
    {
        SCH_CREDENTIALS cred;
        cred.dwVersion = SCH_CREDENTIALS_VERSION;

        TLS_PARAMETERS tlsParams;
        tlsParams.grbitDisabledProtocols = computeDisabledProtocols();
        cred.cTlsParameters = 1;
        cred.pTlsParameters = &tlsParams;

        if (certContext)
        {
            cred.cCreds = 1;
            cred.paCred = &certContext;
        }

        DWORD flags = extraFlags;
        if (kind == Kind.client)
        {
            if (verify == Verify.none || peerRootStore !is null)
                // Manual: either skipping all verification, or using a custom
                // root store that we validate manually post-handshake.
                flags |= SCH_CRED_MANUAL_CRED_VALIDATION | SCH_CRED_NO_DEFAULT_CREDS;
            else
                flags |= SCH_CRED_AUTO_CRED_VALIDATION | SCH_CRED_NO_DEFAULT_CREDS
                       | SCH_CRED_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT;
        }
        cred.dwFlags = flags;

        CredHandle h;
        TimeStamp ts;
        ULONG usage = (kind == Kind.client) ? SECPKG_CRED_OUTBOUND : SECPKG_CRED_INBOUND;

        SECURITY_STATUS s = AcquireCredentialsHandleW(
            null,
            cast(SEC_WCHAR*) UNISP_NAME_W.ptr,
            usage,
            null,
            cast(void*) &cred,
            null, null,
            &h, &ts);
        sspiEnforce(s == SEC_E_OK, "AcquireCredentialsHandleW", s);
        return h;
    }

    private DWORD computeDisabledProtocols() const nothrow @nogc
    {
        DWORD allClient = SP_PROT_SSL3_CLIENT | SP_PROT_TLS1_CLIENT
            | SP_PROT_TLS1_1_CLIENT | SP_PROT_TLS1_2_CLIENT | SP_PROT_TLS1_3_CLIENT;
        DWORD allServer = SP_PROT_SSL3_SERVER | SP_PROT_TLS1_SERVER
            | SP_PROT_TLS1_1_SERVER | SP_PROT_TLS1_2_SERVER | SP_PROT_TLS1_3_SERVER;
        DWORD all = (kind == Kind.client) ? allClient : allServer;

        DWORD enabled = 0;
        SSLVersion lo = (minVersion == SSLVersion.unspecified) ? SSLVersion.tls12 : minVersion;
        SSLVersion hi = (maxVersion == SSLVersion.unspecified) ? SSLVersion.tls13 : maxVersion;

        DWORD bitFor(SSLVersion v) const nothrow @nogc
        {
            final switch (v) with (SSLVersion)
            {
                case unspecified: return 0;
                case ssl3:  return (kind==Kind.client) ? SP_PROT_SSL3_CLIENT  : SP_PROT_SSL3_SERVER;
                case tls1:  return (kind==Kind.client) ? SP_PROT_TLS1_CLIENT  : SP_PROT_TLS1_SERVER;
                case tls11: return (kind==Kind.client) ? SP_PROT_TLS1_1_CLIENT: SP_PROT_TLS1_1_SERVER;
                case tls12: return (kind==Kind.client) ? SP_PROT_TLS1_2_CLIENT: SP_PROT_TLS1_2_SERVER;
                case tls13: return (kind==Kind.client) ? SP_PROT_TLS1_3_CLIENT: SP_PROT_TLS1_3_SERVER;
            }
        }
        for (SSLVersion v = lo; v <= hi; v = cast(SSLVersion)(v + 1))
            enabled |= bitFor(v);
        return all & ~enabled;
    }
}

// =============================================================================

/// `SSLAdapter` implementation backed by Windows SChannel.
class SChannelAdapter : SSLAdapter
{
    SChannelContext context;
    private CredHandle hCreds;
    private bool credsAcquired;
    private CtxtHandle hCtxt;
    private bool ctxtCreated;
    private bool ctxtComplete;
    private SecPkgContext_StreamSizes streamSizes;
    private string targetName;      // for InitializeSecurityContextW pszTargetName
    private wstring targetNameW;    // UTF-16 form, NUL-terminated
    private ConnectionState connectionState;
    private ubyte[] rIn;            // incoming ciphertext accumulation buffer

    this(SChannelContext context, IConnection next)
    {
        this.context = context;
        super(next);
        if (next.state == ConnectionState.connected)
            onConnect();
    }

    override void onConnect()
    {
        debug(SCHANNEL) stderr.writeln("SChannel: transport connected, beginning handshake");
        try
        {
            hCreds = context.acquireCredentials();
            credsAcquired = true;
            connectionState = ConnectionState.connecting;
            if (context.kind == SSLContext.Kind.client)
                stepClientHandshake();
            // Server side waits for the first ClientHello via onReadData.
        }
        catch (Exception e)
        {
            debug(SCHANNEL) stderr.writefln("SChannel: handshake init failed: %s", e.msg);
            disconnect(e.msg.nonNull, DisconnectType.error);
        }
    }

    override void onReadData(Data data)
    {
        debug(SCHANNEL_DATA) stderr.writefln(
            "SChannel: { %d incoming ciphertext bytes", data.length);
        data.enter((scope contents) { rIn ~= cast(const(ubyte)[]) contents; });

        try
        {
            if (connectionState == ConnectionState.connecting)
            {
                if (context.kind == SSLContext.Kind.client)
                    stepClientHandshake();
                else
                    stepServerHandshake();
                if (connectionState != ConnectionState.connected)
                    return;
            }
            decryptLoop();
        }
        catch (Exception e)
        {
            debug(SCHANNEL) stderr.writefln("SChannel: error in onReadData: %s", e.msg);
            if (next.state != ConnectionState.disconnecting
                    && next.state != ConnectionState.disconnected)
                disconnect(e.msg.nonNull, DisconnectType.error);
        }
    }

    override void send(scope Data[] data, int priority = DEFAULT_PRIORITY)
    {
        if (state != ConnectionState.connected)
            assert(false, "Attempting to send to a non-connected SChannel adapter");
        foreach (datum; data)
        {
            if (!datum.length) continue;
            datum.enter((scope contents) { encryptAndSend(contents, priority); });
        }
    }

    alias send = SSLAdapter.send;

    override @property ConnectionState state()
    {
        if (next.state == ConnectionState.connecting)
            return next.state;
        return connectionState;
    }

    override void disconnect(string reason, DisconnectType type)
    {
        debug(SCHANNEL) stderr.writefln("SChannel: disconnect('%s')", reason);
        if (ctxtCreated && ctxtComplete && type == DisconnectType.requested)
        {
            try sendCloseNotify();
            catch (Exception e)
                debug(SCHANNEL) stderr.writefln(
                    "SChannel: close_notify failed: %s", e.msg);
            connectionState = ConnectionState.disconnecting;
        }
        super.disconnect(reason, type);
    }

    override void onDisconnect(string reason, DisconnectType type)
    {
        debug(SCHANNEL) stderr.writefln("SChannel: onDisconnect('%s')", reason);
        cleanupContext();
        connectionState = ConnectionState.disconnected;
        super.onDisconnect(reason, type);
    }

    override void setHostName(string hostname, ushort port = 0, string service = null)
    {
        targetName  = hostname;
        targetNameW = (hostname ~ "\0").to!wstring;
    }

    override SChannelCertificate getHostCertificate()
    {
        if (!ctxtCreated) throw new Exception("No active SChannel context");
        PCCERT_CONTEXT cert;
        SECURITY_STATUS s = QueryContextAttributesW(
            &hCtxt, SECPKG_ATTR_LOCAL_CERT_CONTEXT, &cert);
        sspiEnforce(s == SEC_E_OK, "QueryContextAttributesW(LOCAL_CERT_CONTEXT)", s);
        return new SChannelCertificate(cert);
    }

    override SChannelCertificate getPeerCertificate()
    {
        if (!ctxtCreated) throw new Exception("No active SChannel context");
        PCCERT_CONTEXT cert;
        SECURITY_STATUS s = QueryContextAttributesW(
            &hCtxt, SECPKG_ATTR_REMOTE_CERT_CONTEXT, &cert);
        sspiEnforce(s == SEC_E_OK, "QueryContextAttributesW(REMOTE_CERT_CONTEXT)", s);
        return new SChannelCertificate(cert);
    }

    // SChannel does not expose the SNI hostname through any documented
    // QueryContextAttributes attribute (verified against Microsoft's
    // QueryContextAttributes (Schannel) reference and by enumerating all 256
    // attribute IDs on Windows 11 24H2). Retrieving it server-side would
    // require parsing the ClientHello bytes ourselves. Until a caller actually
    // needs it, return null on both sides — same choice as rust-native-tls.
    override string getSNIHostname() { return null; }

protected:

    private DWORD clientReqFlags() const nothrow @nogc
    {
        return ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT
             | ISC_REQ_CONFIDENTIALITY | ISC_REQ_ALLOCATE_MEMORY
             | ISC_REQ_STREAM | ISC_REQ_USE_SUPPLIED_CREDS
             | ISC_REQ_EXTENDED_ERROR;
    }

    private DWORD serverReqFlags() const nothrow @nogc
    {
        return ASC_REQ_SEQUENCE_DETECT | ASC_REQ_REPLAY_DETECT
             | ASC_REQ_CONFIDENTIALITY | ASC_REQ_ALLOCATE_MEMORY
             | ASC_REQ_STREAM | ASC_REQ_EXTENDED_ERROR;
    }

    private void stepClientHandshake()
    {
        DWORD reqFlags = clientReqFlags();
        bool firstCall = !ctxtCreated;
        bool again = true;
        while (again)
        {
            again = false;
            const(ubyte)[] in0 = rIn;

            SecBuffer[2] inBufs;
            inBufs[0].BufferType = SECBUFFER_TOKEN;
            inBufs[0].cbBuffer   = cast(ULONG) in0.length;
            inBufs[0].pvBuffer   = cast(void*) in0.ptr;
            inBufs[1].BufferType = SECBUFFER_EMPTY;
            SecBufferDesc inDesc;
            inDesc.ulVersion = SECBUFFER_VERSION;
            inDesc.cBuffers  = 2;
            inDesc.pBuffers  = inBufs.ptr;

            SecBuffer[2] outBufs;
            outBufs[0].BufferType = SECBUFFER_TOKEN;
            outBufs[1].BufferType = SECBUFFER_ALERT;
            SecBufferDesc outDesc;
            outDesc.ulVersion = SECBUFFER_VERSION;
            outDesc.cBuffers  = 2;
            outDesc.pBuffers  = outBufs.ptr;

            ULONG attr;
            TimeStamp ts;
            SECURITY_STATUS s = InitializeSecurityContextW(
                &hCreds,
                ctxtCreated ? &hCtxt : null,
                targetNameW.length ? cast(SEC_WCHAR*) targetNameW.ptr : null,
                reqFlags,
                0, 0,
                firstCall ? null : &inDesc,
                0,
                ctxtCreated ? null : &hCtxt,
                &outDesc,
                &attr, &ts);

            ctxtCreated = true;
            firstCall   = false;

            sendAndFreeOutputBuffers(outBufs[]);

            // Consume bytes from rIn that ISC processed.
            if (s != SEC_E_INCOMPLETE_MESSAGE && in0.length)
                advanceRIn(in0.length - (
                    (inBufs[1].BufferType == SECBUFFER_EXTRA) ? inBufs[1].cbBuffer : 0));

            switch (s)
            {
                case SEC_E_OK:
                    handshakeComplete();
                    return;
                case SEC_I_CONTINUE_NEEDED:
                    return;
                case SEC_E_INCOMPLETE_MESSAGE:
                    return;
                case SEC_I_INCOMPLETE_CREDENTIALS:
                    again = true;
                    continue;
                default:
                    sspiEnforce(false, "InitializeSecurityContextW", s);
                    assert(false);
            }
        }
    }

    private void stepServerHandshake()
    {
        DWORD reqFlags = serverReqFlags();
        bool firstCall = !ctxtCreated;
        bool again = true;
        while (again)
        {
            again = false;
            const(ubyte)[] in0 = rIn;
            if (!in0.length && firstCall)
                return; // wait for ClientHello

            SecBuffer[2] inBufs;
            inBufs[0].BufferType = SECBUFFER_TOKEN;
            inBufs[0].cbBuffer   = cast(ULONG) in0.length;
            inBufs[0].pvBuffer   = cast(void*) in0.ptr;
            inBufs[1].BufferType = SECBUFFER_EMPTY;
            SecBufferDesc inDesc;
            inDesc.ulVersion = SECBUFFER_VERSION;
            inDesc.cBuffers  = 2;
            inDesc.pBuffers  = inBufs.ptr;

            SecBuffer[2] outBufs;
            outBufs[0].BufferType = SECBUFFER_TOKEN;
            outBufs[1].BufferType = SECBUFFER_ALERT;
            SecBufferDesc outDesc;
            outDesc.ulVersion = SECBUFFER_VERSION;
            outDesc.cBuffers  = 2;
            outDesc.pBuffers  = outBufs.ptr;

            ULONG attr;
            TimeStamp ts;
            SECURITY_STATUS s = AcceptSecurityContext(
                &hCreds,
                ctxtCreated ? &hCtxt : null,
                &inDesc,
                reqFlags,
                0,
                ctxtCreated ? null : &hCtxt,
                &outDesc,
                &attr, &ts);

            ctxtCreated = true;
            firstCall   = false;

            sendAndFreeOutputBuffers(outBufs[]);

            if (s != SEC_E_INCOMPLETE_MESSAGE && in0.length)
                advanceRIn(in0.length - (
                    (inBufs[1].BufferType == SECBUFFER_EXTRA) ? inBufs[1].cbBuffer : 0));

            switch (s)
            {
                case SEC_E_OK:
                    handshakeComplete();
                    return;
                case SEC_I_CONTINUE_NEEDED:
                    return;
                case SEC_E_INCOMPLETE_MESSAGE:
                    return;
                default:
                    sspiEnforce(false, "AcceptSecurityContext", s);
                    assert(false);
            }
        }
    }

    private void handshakeComplete()
    {
        bool firstTime = !ctxtComplete;
        ctxtComplete = true;
        connectionState = ConnectionState.connected;

        if (firstTime)
        {
            SECURITY_STATUS s = QueryContextAttributesW(
                &hCtxt, SECPKG_ATTR_STREAM_SIZES, &streamSizes);
            sspiEnforce(s == SEC_E_OK, "QueryContextAttributesW(STREAM_SIZES)", s);

            if (context.kind == SSLContext.Kind.client && context.peerRootStore !is null)
                verifyPeerCertificate();

            // Fire onConnect only on the initial handshake completion, not on
            // re-completions triggered by TLS 1.3 post-handshake messages.
            super.onConnect();
        }
    }

    private void verifyPeerCertificate()
    {
        // Manual chain validation using the custom root store from the context.
        // Only invoked when context.peerRootStore != null.
        PCCERT_CONTEXT peerCert;
        SECURITY_STATUS qs = QueryContextAttributesW(
            &hCtxt, SECPKG_ATTR_REMOTE_CERT_CONTEXT, &peerCert);
        sspiEnforce(qs == SEC_E_OK, "QueryContextAttributesW(REMOTE_CERT_CONTEXT)", qs);
        scope(exit) CertFreeCertificateContext(peerCert);

        CERT_CHAIN_PARA chainPara;
        chainPara.cbSize = CERT_CHAIN_PARA.sizeof;
        PCCERT_CHAIN_CONTEXT pChain;
        BOOL ok = CertGetCertificateChain(
            null, peerCert, null,
            context.peerRootStore,
            &chainPara,
            0, null, &pChain);
        sspiEnforce(ok != 0, "CertGetCertificateChain");
        scope(exit) CertFreeCertificateChain(pChain);

        SSL_EXTRA_CERT_CHAIN_POLICY_PARA sslPolicy;
        sslPolicy.cbStruct      = SSL_EXTRA_CERT_CHAIN_POLICY_PARA.sizeof;
        sslPolicy.dwAuthType    = AUTHTYPE_SERVER;
        sslPolicy.fdwChecks     = 0;
        sslPolicy.pwszServerName = targetNameW.length
            ? cast(LPWSTR) targetNameW.ptr : null;

        CERT_CHAIN_POLICY_PARA policyPara;
        policyPara.cbSize            = CERT_CHAIN_POLICY_PARA.sizeof;
        policyPara.dwFlags           = 0;
        policyPara.pvExtraPolicyPara = cast(void*) &sslPolicy;

        CERT_CHAIN_POLICY_STATUS policyStatus;
        policyStatus.cbSize = CERT_CHAIN_POLICY_STATUS.sizeof;
        ok = CertVerifyCertificateChainPolicy(
            CERT_CHAIN_POLICY_SSL, pChain, &policyPara, &policyStatus);
        sspiEnforce(ok != 0, "CertVerifyCertificateChainPolicy");
        if (policyStatus.dwError)
        {
            import std.format : format;
            throw new Exception(format(
                "SChannel: peer certificate verification failed (error=0x%08X)",
                policyStatus.dwError));
        }
    }

    private void decryptLoop()
    {
        Data clearText;
        bool gotData = true;
        while (gotData && rIn.length)
        {
            gotData = false;
            const(ubyte)[] in0 = rIn;

            SecBuffer[4] bufs;
            bufs[0].BufferType = SECBUFFER_DATA;
            bufs[0].cbBuffer   = cast(ULONG) in0.length;
            bufs[0].pvBuffer   = cast(void*) in0.ptr;
            bufs[1].BufferType = SECBUFFER_EMPTY;
            bufs[2].BufferType = SECBUFFER_EMPTY;
            bufs[3].BufferType = SECBUFFER_EMPTY;
            SecBufferDesc desc;
            desc.ulVersion = SECBUFFER_VERSION;
            desc.cBuffers  = 4;
            desc.pBuffers  = bufs.ptr;

            SECURITY_STATUS s = DecryptMessage(&hCtxt, &desc, 0, null);
            debug(SCHANNEL) stderr.writefln(
                "SChannel: DecryptMessage on %d bytes -> 0x%x", in0.length, s);

            if (s == SEC_E_INCOMPLETE_MESSAGE)
                return;

            if (s == SEC_I_CONTEXT_EXPIRED)
            {
                // Peer sent TLS close_notify alert.
                if (clearText.length) super.onReadData(clearText);
                disconnect("Connection terminated by remote peer", DisconnectType.graceful);
                return;
            }

            if (s == SEC_I_RENEGOTIATE)
            {
                // DecryptMessage returns SEC_I_RENEGOTIATE for any post-handshake
                // message in both TLS 1.2 (HelloRequest / renegotiation) and
                // TLS 1.3 (NewSessionTicket, KeyUpdate).  This path is load-bearing
                // for TLS 1.3: Microsoft's server sends 2 NewSessionTicket messages
                // immediately after the handshake completes.  Without re-entering the
                // handshake state machine here, every TLS 1.3 session fails on the
                // first application read.  The unprocessed renegotiation tokens are
                // placed in the SECBUFFER_EXTRA output buffer; we feed them back
                // through InitializeSecurityContext / AcceptSecurityContext until the
                // engine returns SEC_E_OK, then resume normal decryption.
                debug(SCHANNEL) stderr.writeln(
                    "SChannel: DecryptMessage returned SEC_I_RENEGOTIATE — "
                    ~ "re-entering handshake for post-handshake message "
                    ~ "(TLS 1.3 NewSessionTicket/KeyUpdate or TLS 1.2 HelloRequest)");

                size_t extraLen = 0;
                foreach (ref b; bufs)
                    if (b.BufferType == SECBUFFER_EXTRA && b.cbBuffer)
                        extraLen = b.cbBuffer;
                advanceRIn(in0.length - extraLen);

                if (clearText.length)
                {
                    super.onReadData(clearText);
                    clearText = Data.init;
                }

                connectionState = ConnectionState.connecting;
                if (context.kind == SSLContext.Kind.client)
                    stepClientHandshake();
                else
                    stepServerHandshake();

                if (connectionState != ConnectionState.connected)
                    return;
                gotData = true;
                continue;
            }

            sspiEnforce(s == SEC_E_OK, "DecryptMessage", s);

            size_t extraLen = 0;
            foreach (ref b; bufs)
            {
                if (b.BufferType == SECBUFFER_DATA && b.cbBuffer)
                    clearText ~= Data((cast(ubyte*) b.pvBuffer)[0 .. b.cbBuffer]);
                else if (b.BufferType == SECBUFFER_EXTRA && b.cbBuffer)
                    extraLen = b.cbBuffer;
            }
            advanceRIn(in0.length - extraLen);
            gotData = true;
        }

        if (clearText.length)
            super.onReadData(clearText);
    }

    private void encryptAndSend(scope const(ubyte)[] data, int priority)
    {
        ULONG maxChunk  = streamSizes.cbMaximumMessage;
        ULONG headerLen = streamSizes.cbHeader;
        ULONG trailerLen = streamSizes.cbTrailer;
        assert(maxChunk > 0, "STREAM_SIZES not initialized");

        while (data.length)
        {
            ULONG chunk = cast(ULONG) min(data.length, cast(size_t) maxChunk);
            ubyte[] buf = new ubyte[headerLen + chunk + trailerLen];
            buf[headerLen .. headerLen + chunk] = data[0 .. chunk];

            SecBuffer[4] bufs;
            bufs[0].BufferType = SECBUFFER_STREAM_HEADER;
            bufs[0].cbBuffer   = headerLen;
            bufs[0].pvBuffer   = buf.ptr;
            bufs[1].BufferType = SECBUFFER_DATA;
            bufs[1].cbBuffer   = chunk;
            bufs[1].pvBuffer   = buf.ptr + headerLen;
            bufs[2].BufferType = SECBUFFER_STREAM_TRAILER;
            bufs[2].cbBuffer   = trailerLen;
            bufs[2].pvBuffer   = buf.ptr + headerLen + chunk;
            bufs[3].BufferType = SECBUFFER_EMPTY;
            SecBufferDesc desc;
            desc.ulVersion = SECBUFFER_VERSION;
            desc.cBuffers  = 4;
            desc.pBuffers  = bufs.ptr;

            SECURITY_STATUS s = EncryptMessage(&hCtxt, 0, &desc, 0);
            sspiEnforce(s == SEC_E_OK, "EncryptMessage", s);

            ULONG total = bufs[0].cbBuffer + bufs[1].cbBuffer + bufs[2].cbBuffer;
            next.send(Data(buf[0 .. total]), priority);
            data = data[chunk .. $];
        }
    }

    private void sendCloseNotify()
    {
        DWORD shutdownToken = SCHANNEL_SHUTDOWN;
        SecBuffer ctlBuf;
        ctlBuf.BufferType = SECBUFFER_TOKEN;
        ctlBuf.cbBuffer   = DWORD.sizeof;
        ctlBuf.pvBuffer   = &shutdownToken;
        SecBufferDesc ctlDesc;
        ctlDesc.ulVersion = SECBUFFER_VERSION;
        ctlDesc.cBuffers  = 1;
        ctlDesc.pBuffers  = &ctlBuf;
        SECURITY_STATUS s = ApplyControlToken(&hCtxt, &ctlDesc);
        sspiEnforce(s == SEC_E_OK, "ApplyControlToken(SCHANNEL_SHUTDOWN)", s);

        SecBuffer outBuf;
        outBuf.BufferType = SECBUFFER_TOKEN;
        SecBufferDesc outDesc;
        outDesc.ulVersion = SECBUFFER_VERSION;
        outDesc.cBuffers  = 1;
        outDesc.pBuffers  = &outBuf;

        ULONG attr;
        TimeStamp ts;
        if (context.kind == SSLContext.Kind.client)
        {
            s = InitializeSecurityContextW(
                &hCreds, &hCtxt,
                targetNameW.length ? cast(SEC_WCHAR*) targetNameW.ptr : null,
                clientReqFlags(), 0, 0, null, 0, &hCtxt, &outDesc, &attr, &ts);
        }
        else
        {
            s = AcceptSecurityContext(
                &hCreds, &hCtxt, null,
                serverReqFlags(), 0, &hCtxt, &outDesc, &attr, &ts);
        }

        if (outBuf.cbBuffer && outBuf.pvBuffer)
        {
            next.send(Data((cast(ubyte*) outBuf.pvBuffer)[0 .. outBuf.cbBuffer]));
            FreeContextBuffer(outBuf.pvBuffer);
        }
    }

    private void cleanupContext()
    {
        if (ctxtCreated)
        {
            DeleteSecurityContext(&hCtxt);
            ctxtCreated  = false;
            ctxtComplete = false;
        }
        if (credsAcquired)
        {
            FreeCredentialsHandle(&hCreds);
            credsAcquired = false;
        }
        rIn          = null;
        targetName   = null;
        targetNameW  = null;
    }

    private void advanceRIn(size_t n)
    {
        if (n >= rIn.length) rIn = null;
        else                 rIn = rIn[n .. $];
    }

    private void sendAndFreeOutputBuffers(SecBuffer[] bufs)
    {
        foreach (ref b; bufs)
        {
            if (b.cbBuffer && b.pvBuffer)
            {
                next.send(Data((cast(ubyte*) b.pvBuffer)[0 .. b.cbBuffer]));
                FreeContextBuffer(b.pvBuffer);
                b.pvBuffer = null;
                b.cbBuffer = 0;
            }
        }
    }
}

// =============================================================================

/// `SSLCertificate` implementation wrapping a Windows `PCCERT_CONTEXT`.
class SChannelCertificate : SSLCertificate
{
    PCCERT_CONTEXT cert;

    this(PCCERT_CONTEXT cert) { this.cert = cert; }

    ~this() { if (cert) CertFreeCertificateContext(cert); }

    override string getSubjectName()
    {
        wchar[256] buf;
        DWORD got = CertGetNameStringW(
            cert, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, null,
            buf.ptr, cast(DWORD) buf.length);
        if (got == 0) return "";
        return (cast(wstring) buf[0 .. got - 1]).toUTF8();  // got includes NUL
    }
}

// =============================================================================
// Self-registration
// =============================================================================

static this()
{
    ssl = new SChannelProvider();
}

// =============================================================================
// Helpers
// =============================================================================

private void sspiEnforce(bool ok, string what,
    SECURITY_STATUS s = SEC_E_OK,
    string file = __FILE__, size_t line = __LINE__)
{
    if (ok) return;
    string msg = "SChannel: " ~ what ~ " failed";
    if (s != SEC_E_OK)
    {
        import std.format : format;
        msg ~= format(" (status=0x%08X)", cast(uint) s);
    }
    throw new Exception(msg, file, line);
}

/// Delete the CNG or legacy-CSP key container that PFXImportCertStore (dwFlags=0)
/// created for this certificate.  Mirrors .NET's
/// SafeCertContextHandleWithKeyContainerDeletion.DeleteKeyContainer.
/// Failures are silently swallowed — we log but do not throw, exactly as .NET does.
private void deleteKeyContainerSilent(PCCERT_CONTEXT cert) nothrow
{
    import core.stdc.stdlib : malloc, free;
    try
    {
        DWORD cb = 0;
        if (!CertGetCertificateContextProperty(
                cert, CERT_KEY_PROV_INFO_PROP_ID, null, &cb))
            return; // no private key registered — nothing to delete

        // Use malloc to avoid GC allocation in a destructor-called path.
        auto buf = cast(ubyte*) malloc(cb);
        if (!buf) return;
        scope(exit) free(buf);
        if (!CertGetCertificateContextProperty(
                cert, CERT_KEY_PROV_INFO_PROP_ID, buf, &cb))
            return;

        auto pInfo = cast(CRYPT_KEY_PROV_INFO*) buf;

        if (pInfo.dwProvType == 0)
        {
            // CNG provider path
            NCRYPT_PROV_HANDLE hProv;
            if (NCryptOpenStorageProvider(&hProv, pInfo.pwszProvName, 0) == 0 /*ERROR_SUCCESS*/)
            {
                scope(exit) NCryptFreeObject(hProv);
                NCRYPT_KEY_HANDLE hKey;
                DWORD openFlags = (pInfo.dwFlags & CRYPT_MACHINE_KEYSET)
                    ? NCRYPT_MACHINE_KEY_FLAG : 0;
                if (NCryptOpenKey(hProv, &hKey, pInfo.pwszContainerName, 0, openFlags) == 0)
                    NCryptDeleteKey(hKey, NCRYPT_SILENT_FLAG);
                    // NCryptDeleteKey frees hKey on success; no scope(exit) needed
            }
        }
        else
        {
            // Legacy CAPI / CSP path — call purely for the delete side-effect
            HCRYPTPROV hProv = 0;
            DWORD flags = (pInfo.dwFlags & CRYPT_MACHINE_KEYSET) | CRYPT_DELETEKEYSET;
            CryptAcquireContextW(&hProv, pInfo.pwszContainerName,
                pInfo.pwszProvName, pInfo.dwProvType, flags);
            // hProv will be null on success; return value intentionally ignored
        }
    }
    catch (Exception e)
    {
        debug(SCHANNEL) { import std.stdio : stderr; stderr.writefln(
            "SChannel: deleteKeyContainerSilent failed (ignored): %s", e.msg); }
    }
}

// =============================================================================
// Unittests
// =============================================================================

debug (ae_unittest) import ae.net.ssl.test;
debug(ae_unittest) unittest { testSSL(new SChannelProvider); }

// PFX echo test: load a pre-baked self-signed PFX, run an SChannel server,
// connect with a client that has peer-verify disabled, send "hello", receive "HELLO".
// PFX: CN=localhost, password="test", 2048-bit RSA, generated by OpenSSL.
debug(ae_unittest) unittest
{
    import std.ascii : toUpper;

    // Pre-baked self-signed PFX (CN=localhost, password "test").
    // Generated by: openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem
    //               -days 3650 -subj /CN=localhost -passout pass:
    //               openssl pkcs12 -export -out test.pfx -inkey key.pem
    //               -in cert.pem -passout pass:test
    static immutable ubyte[] testPfxBytes = [
        0x30, 0x82, 0x09, 0xf7, 0x02, 0x01, 0x03, 0x30, 0x82, 0x09, 0xa5, 0x06, 0x09, 0x2a, 0x86, 0x48,
        0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01, 0xa0, 0x82, 0x09, 0x96, 0x04, 0x82, 0x09, 0x92, 0x30, 0x82,
        0x09, 0x8e, 0x30, 0x82, 0x03, 0xfa, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07,
        0x06, 0xa0, 0x82, 0x03, 0xeb, 0x30, 0x82, 0x03, 0xe7, 0x02, 0x01, 0x00, 0x30, 0x82, 0x03, 0xe0,
        0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01, 0x30, 0x5f, 0x06, 0x09, 0x2a,
        0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0d, 0x30, 0x52, 0x30, 0x31, 0x06, 0x09, 0x2a, 0x86,
        0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0c, 0x30, 0x24, 0x04, 0x10, 0x91, 0xe0, 0xca, 0x9e, 0x2b,
        0x33, 0xf2, 0xac, 0xa0, 0xfc, 0x3f, 0xe9, 0x4e, 0xb3, 0x3e, 0xc8, 0x02, 0x02, 0x08, 0x00, 0x30,
        0x0c, 0x06, 0x08, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x09, 0x05, 0x00, 0x30, 0x1d, 0x06,
        0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2a, 0x04, 0x10, 0xb8, 0x6b, 0x60, 0x5c,
        0xba, 0xdb, 0xa5, 0x50, 0x13, 0xe0, 0x98, 0xdd, 0x23, 0x6c, 0x87, 0xa9, 0x80, 0x82, 0x03, 0x70,
        0x63, 0x7b, 0x29, 0x5f, 0x6f, 0x99, 0x97, 0x4c, 0xa8, 0xb1, 0x9d, 0xc0, 0x95, 0x0b, 0x2d, 0xd0,
        0x93, 0xb8, 0x1c, 0xdb, 0x89, 0x10, 0x99, 0x27, 0x12, 0xcb, 0x07, 0xd5, 0x3f, 0x28, 0x1f, 0x07,
        0x3a, 0xae, 0x31, 0xb4, 0x92, 0x82, 0xda, 0x0c, 0xff, 0xe6, 0x00, 0x28, 0x9c, 0x6f, 0x33, 0x11,
        0x09, 0x9c, 0x04, 0xc3, 0xe2, 0x24, 0xcb, 0xcf, 0xa6, 0x58, 0xa4, 0xa7, 0x77, 0x7c, 0x59, 0xdd,
        0xaf, 0xbd, 0x29, 0xb3, 0xcb, 0x50, 0x73, 0x5e, 0xd1, 0xf1, 0x17, 0x7d, 0x70, 0xfd, 0xa9, 0x76,
        0x9f, 0x3e, 0xfc, 0x5f, 0xc0, 0xbc, 0xdd, 0x6e, 0xdb, 0x72, 0x0b, 0xcc, 0x79, 0x07, 0xc1, 0x89,
        0x8f, 0x17, 0xc0, 0xe0, 0x6e, 0xc2, 0xc0, 0x2b, 0xfa, 0x67, 0x60, 0x56, 0x5f, 0x7a, 0xe8, 0xdf,
        0x41, 0xb3, 0x9a, 0xc4, 0xb4, 0xfd, 0x4c, 0x72, 0xe0, 0x9b, 0x8d, 0x4a, 0x39, 0xaa, 0x11, 0xbc,
        0x96, 0x15, 0xc0, 0xdc, 0xe7, 0xe3, 0x9c, 0xee, 0x07, 0x1d, 0x51, 0x87, 0xaa, 0xbc, 0xc5, 0x8a,
        0xb9, 0x94, 0x24, 0x95, 0x99, 0xee, 0x21, 0xf8, 0x6f, 0x5a, 0x15, 0x5c, 0xc0, 0x6b, 0xde, 0xab,
        0xb4, 0x19, 0x54, 0x2a, 0x05, 0x0a, 0x4a, 0x0f, 0x97, 0x66, 0x46, 0x10, 0xbf, 0x49, 0xa9, 0x82,
        0xe6, 0x2e, 0x75, 0x63, 0x57, 0x5e, 0x3d, 0x0a, 0x6d, 0x1c, 0x52, 0xaa, 0x1c, 0x6c, 0x26, 0x54,
        0xf0, 0x14, 0x8c, 0xe7, 0xc9, 0x9f, 0x68, 0x39, 0xe4, 0xa1, 0xe5, 0xab, 0xc0, 0xb7, 0x9d, 0xd5,
        0x44, 0xec, 0x36, 0x41, 0x74, 0x2f, 0x27, 0x52, 0x35, 0x36, 0x0d, 0xbd, 0x79, 0x10, 0x3a, 0xc4,
        0xee, 0x3d, 0xb2, 0x05, 0x43, 0xbd, 0xd3, 0x6c, 0x9e, 0x6a, 0x6f, 0x64, 0x50, 0x6c, 0x6a, 0x3a,
        0x91, 0x28, 0x0d, 0x2b, 0x86, 0x8c, 0x54, 0xe5, 0x09, 0x1a, 0xf4, 0x6d, 0xab, 0xfa, 0x73, 0x95,
        0x60, 0xce, 0x4b, 0x2f, 0x6b, 0xb5, 0xcc, 0x9b, 0xa2, 0x16, 0xd9, 0xb9, 0x77, 0xae, 0xc3, 0x22,
        0x5c, 0xcd, 0x5a, 0xac, 0xbb, 0x3d, 0xaf, 0x94, 0x59, 0x0d, 0x2a, 0xf7, 0xd4, 0x6d, 0x9e, 0x4c,
        0xbf, 0x72, 0xd6, 0x5a, 0xc8, 0x1a, 0x8f, 0x89, 0x1e, 0x33, 0xc4, 0x6f, 0x16, 0xd1, 0xcf, 0xd9,
        0x1c, 0xfa, 0x3c, 0x45, 0xcb, 0x50, 0x20, 0x2e, 0x5e, 0xec, 0xe7, 0xaa, 0x13, 0x35, 0xc4, 0x2e,
        0x9a, 0xe3, 0xff, 0x39, 0x4d, 0xdd, 0x5d, 0xe6, 0x06, 0x47, 0x77, 0xaf, 0x5c, 0x0d, 0xed, 0x53,
        0x5d, 0x9b, 0xd3, 0xd2, 0x14, 0xe0, 0x03, 0x03, 0xc5, 0xf9, 0x7e, 0xe8, 0x5f, 0x21, 0xa6, 0x59,
        0x11, 0xa2, 0x32, 0x51, 0x16, 0x84, 0x4b, 0x1f, 0x6f, 0xfc, 0x97, 0x9f, 0x68, 0x15, 0xbe, 0xee,
        0x17, 0x3b, 0x81, 0xce, 0x48, 0xc0, 0xd9, 0x9d, 0x6f, 0x76, 0xc5, 0xa8, 0x61, 0x52, 0x7c, 0x78,
        0x9d, 0xfc, 0x0f, 0xeb, 0xd7, 0x97, 0x19, 0x74, 0x62, 0x3f, 0x86, 0x66, 0x35, 0x94, 0xb0, 0x7e,
        0xf2, 0xbf, 0x92, 0x37, 0x1b, 0xe7, 0xdd, 0x10, 0xbf, 0x09, 0xc7, 0x9d, 0x01, 0xb9, 0x56, 0xad,
        0xb6, 0x35, 0x3b, 0x06, 0xbf, 0xe9, 0xdd, 0xa0, 0x2f, 0x52, 0xcc, 0x04, 0xd5, 0x5d, 0xc5, 0x5d,
        0x21, 0xdc, 0x4f, 0xb6, 0xd3, 0xe9, 0x77, 0x9e, 0x7c, 0x0a, 0xc0, 0xdb, 0x1f, 0x01, 0x2c, 0xf3,
        0xcb, 0x04, 0xc4, 0xf2, 0x97, 0x43, 0x0b, 0x29, 0x4b, 0x35, 0x3b, 0xca, 0x9e, 0x2f, 0x04, 0x29,
        0xda, 0x61, 0x5b, 0xc1, 0xf4, 0x12, 0xe5, 0xec, 0x55, 0xce, 0x17, 0x86, 0x37, 0x89, 0x0c, 0xef,
        0xb3, 0x5e, 0x14, 0x93, 0x4f, 0x14, 0x02, 0xfb, 0x79, 0xba, 0xc8, 0x15, 0x2a, 0x21, 0x28, 0x90,
        0x28, 0xc3, 0xa1, 0x9c, 0xbe, 0xb4, 0xc4, 0x9f, 0x6a, 0xb5, 0x1a, 0x67, 0x41, 0x60, 0x9d, 0xbc,
        0xfd, 0x4d, 0x99, 0xf3, 0x77, 0x01, 0x5c, 0x8e, 0x3a, 0xfd, 0xa9, 0x4e, 0x5f, 0x75, 0xc1, 0x07,
        0xed, 0x30, 0x87, 0x23, 0xf6, 0x88, 0xea, 0xba, 0xa5, 0x4a, 0x10, 0x6c, 0x24, 0x5d, 0x28, 0x49,
        0xb8, 0x8d, 0xdf, 0x06, 0xbc, 0xb2, 0x91, 0x78, 0x51, 0x27, 0x24, 0x73, 0x8b, 0x7d, 0x14, 0x75,
        0x5c, 0x56, 0x6d, 0xa7, 0x8a, 0x8e, 0x15, 0x76, 0x7f, 0xd0, 0xfe, 0x39, 0x5d, 0x5a, 0xcd, 0xea,
        0x08, 0x71, 0xec, 0x15, 0x77, 0x36, 0x51, 0xe7, 0x48, 0xa8, 0xce, 0xd2, 0x94, 0x7b, 0x51, 0x31,
        0xb5, 0x61, 0xc8, 0x8b, 0x4a, 0x2a, 0x0e, 0x31, 0x88, 0x3a, 0x6b, 0x2f, 0xdf, 0x71, 0x41, 0xbd,
        0x58, 0xaa, 0x48, 0x0a, 0x98, 0xbf, 0xdc, 0x8e, 0xde, 0xb7, 0x8c, 0x79, 0x9f, 0xb5, 0x36, 0xb5,
        0xd9, 0xe6, 0x92, 0x09, 0xec, 0x6f, 0x14, 0x4d, 0xaf, 0xd2, 0x80, 0xc9, 0x54, 0x43, 0x9d, 0xc8,
        0xeb, 0xf7, 0x69, 0x98, 0x32, 0xb2, 0x3c, 0x7a, 0xef, 0x16, 0xfa, 0xa5, 0x35, 0x41, 0x42, 0x32,
        0x59, 0x8f, 0x08, 0xad, 0xdd, 0x81, 0xca, 0xae, 0xa6, 0x52, 0x48, 0x17, 0x31, 0x74, 0x94, 0x47,
        0x84, 0x3e, 0x16, 0xe2, 0xe1, 0x1a, 0x5a, 0x67, 0xf7, 0x33, 0x6c, 0xbf, 0xc0, 0xd6, 0x9d, 0x1e,
        0xdb, 0x41, 0x90, 0x53, 0x8d, 0xca, 0x28, 0x7e, 0xb5, 0x17, 0xff, 0x41, 0xf7, 0xad, 0xed, 0xb9,
        0x9f, 0x8a, 0xec, 0xe0, 0x31, 0x02, 0x6e, 0xcc, 0xf2, 0x92, 0x07, 0xf2, 0x58, 0xfc, 0xf3, 0x98,
        0x4f, 0x5d, 0x4a, 0x2a, 0x97, 0x1c, 0x2f, 0x90, 0x81, 0xf5, 0xd2, 0xd1, 0x00, 0x3e, 0x01, 0x47,
        0x9f, 0x5c, 0xbc, 0xd6, 0xfe, 0x97, 0xe7, 0xfa, 0xfc, 0xa9, 0x4f, 0xe7, 0x6a, 0x86, 0x09, 0x4b,
        0x43, 0x6e, 0x60, 0xc8, 0x53, 0x17, 0x0f, 0x58, 0x8d, 0xa9, 0x77, 0xc6, 0xd1, 0xeb, 0x7a, 0x96,
        0x94, 0x2a, 0x66, 0x09, 0xd7, 0xc9, 0x24, 0x31, 0x88, 0x43, 0x5b, 0x63, 0x62, 0x02, 0xd6, 0x72,
        0x17, 0x31, 0xf5, 0x9d, 0x12, 0x1b, 0x50, 0xec, 0xdf, 0x84, 0xa2, 0x4e, 0x4d, 0x6a, 0x3a, 0x24,
        0x21, 0xaf, 0x0f, 0x3d, 0xab, 0x07, 0xf1, 0x65, 0x55, 0x00, 0x6c, 0x7a, 0xa5, 0x90, 0xd9, 0x9e,
        0xc4, 0xc9, 0x35, 0x7f, 0x11, 0xcc, 0xbe, 0xe7, 0x90, 0x61, 0x5f, 0x73, 0x43, 0x39, 0x3e, 0x0a,
        0xdf, 0x16, 0x21, 0xe0, 0x0f, 0xba, 0x5f, 0x4f, 0x2d, 0xe5, 0x28, 0x6c, 0xe0, 0x60, 0x2f, 0x5f,
        0x55, 0x55, 0x2f, 0xd5, 0xe6, 0xb2, 0xad, 0x99, 0x20, 0x61, 0xa1, 0x35, 0x3d, 0x54, 0x5a, 0xdf,
        0x3c, 0x4e, 0xe8, 0xca, 0x4f, 0x5e, 0xd1, 0xbc, 0x76, 0x65, 0x33, 0xba, 0x93, 0x38, 0x38, 0x0f,
        0x30, 0x82, 0x05, 0x8c, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01, 0xa0,
        0x82, 0x05, 0x7d, 0x04, 0x82, 0x05, 0x79, 0x30, 0x82, 0x05, 0x75, 0x30, 0x82, 0x05, 0x71, 0x06,
        0x0b, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x0a, 0x01, 0x02, 0xa0, 0x82, 0x05, 0x39,
        0x30, 0x82, 0x05, 0x35, 0x30, 0x5f, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05,
        0x0d, 0x30, 0x52, 0x30, 0x31, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0c,
        0x30, 0x24, 0x04, 0x10, 0xb1, 0xc3, 0x7d, 0xe7, 0xed, 0xff, 0x2f, 0x75, 0x57, 0x6e, 0x0c, 0x63,
        0x25, 0x20, 0xa3, 0xaa, 0x02, 0x02, 0x08, 0x00, 0x30, 0x0c, 0x06, 0x08, 0x2a, 0x86, 0x48, 0x86,
        0xf7, 0x0d, 0x02, 0x09, 0x05, 0x00, 0x30, 0x1d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03,
        0x04, 0x01, 0x2a, 0x04, 0x10, 0x13, 0x4a, 0x8d, 0x42, 0x66, 0x82, 0xf7, 0xc8, 0xe2, 0xb0, 0xb9,
        0xe4, 0x49, 0x15, 0xec, 0x45, 0x04, 0x82, 0x04, 0xd0, 0x98, 0x6e, 0xb5, 0xf4, 0x70, 0x9f, 0x0c,
        0x72, 0x73, 0x86, 0x80, 0xfb, 0xa0, 0x0a, 0x7e, 0x73, 0x24, 0x19, 0xf6, 0x82, 0x6f, 0x10, 0x66,
        0x3d, 0x02, 0x90, 0xa4, 0xee, 0x1f, 0x9a, 0xc9, 0x36, 0x6a, 0x89, 0xc3, 0x84, 0x48, 0x1c, 0x32,
        0xdb, 0x89, 0x44, 0x9f, 0xb7, 0x05, 0x90, 0xff, 0x1c, 0x65, 0x08, 0x47, 0x6f, 0x7b, 0x9a, 0xe1,
        0x5c, 0x89, 0xdb, 0xc6, 0x24, 0x4f, 0x5a, 0xf4, 0xd1, 0x4a, 0xfb, 0x46, 0x06, 0xb5, 0x67, 0xd9,
        0x16, 0x9a, 0x6e, 0x28, 0xdf, 0x65, 0x99, 0x88, 0xda, 0x55, 0xd2, 0xac, 0x18, 0x74, 0x5e, 0xf5,
        0xdf, 0xa0, 0xf8, 0x4e, 0x92, 0x51, 0xef, 0xa1, 0x23, 0x1a, 0x35, 0x89, 0xa5, 0x96, 0xd7, 0x36,
        0x05, 0x14, 0xd5, 0xe8, 0x85, 0x7e, 0xb2, 0x84, 0x38, 0xa1, 0x49, 0xc0, 0x19, 0xde, 0x0a, 0xbb,
        0x00, 0xd1, 0x84, 0x9e, 0x30, 0xfc, 0x9b, 0x34, 0x7a, 0xb7, 0x71, 0xda, 0x14, 0x2c, 0x89, 0x3c,
        0xc9, 0xd8, 0x21, 0x7d, 0xee, 0x87, 0xba, 0xe3, 0x52, 0x84, 0x34, 0x94, 0xc5, 0x24, 0x35, 0x60,
        0xa8, 0x1f, 0x61, 0x13, 0xd6, 0xbd, 0xc8, 0xc5, 0x78, 0xe8, 0x9d, 0x95, 0x0e, 0xbe, 0x0c, 0x22,
        0x6e, 0xc0, 0x49, 0x1f, 0x08, 0x83, 0x58, 0x2e, 0x0b, 0x33, 0xa6, 0x99, 0x0f, 0x27, 0xc8, 0xb0,
        0xea, 0xfe, 0x6d, 0x2d, 0x47, 0x34, 0xd6, 0x01, 0xa8, 0xa7, 0xc1, 0x0a, 0x89, 0xab, 0x75, 0xa6,
        0x3a, 0x4f, 0x25, 0x0e, 0x34, 0xf3, 0x6e, 0xb7, 0xdf, 0xd0, 0xca, 0x16, 0xd0, 0xdb, 0xd3, 0x30,
        0x2f, 0xbd, 0xb5, 0x2a, 0xe9, 0x44, 0xd6, 0xf6, 0x32, 0x20, 0x47, 0xce, 0x2f, 0xe8, 0x83, 0x59,
        0xc2, 0xb2, 0xe3, 0x29, 0xce, 0xa1, 0xab, 0xf4, 0x75, 0x68, 0x67, 0x14, 0x29, 0x86, 0x3d, 0x68,
        0xde, 0xad, 0x4c, 0x9f, 0x15, 0x05, 0xa6, 0xe3, 0xc3, 0x63, 0x80, 0x63, 0x3c, 0xf5, 0xfd, 0x33,
        0x0c, 0x62, 0x42, 0x0e, 0x2a, 0x2c, 0x1c, 0x72, 0xd3, 0xf5, 0x1b, 0x69, 0xc5, 0x41, 0x70, 0x3d,
        0xaa, 0x93, 0xc1, 0x61, 0x45, 0x4b, 0xc2, 0xfd, 0x5b, 0x0c, 0xea, 0xd7, 0x84, 0x40, 0x88, 0x42,
        0x69, 0x85, 0xed, 0xc9, 0x51, 0x9f, 0xd3, 0x97, 0xd9, 0xe6, 0x86, 0xb3, 0x12, 0x9a, 0x9e, 0x1e,
        0x0d, 0xc9, 0xbb, 0x52, 0x0a, 0xba, 0x52, 0x0d, 0x19, 0x29, 0xb1, 0x65, 0x65, 0x27, 0x74, 0x6c,
        0x9c, 0xde, 0x9a, 0x77, 0x05, 0x90, 0xb2, 0xfd, 0xf4, 0x83, 0x69, 0xc0, 0xe6, 0xb9, 0x87, 0x43,
        0xfb, 0x2c, 0xbc, 0x76, 0xc6, 0x6f, 0x27, 0x4f, 0xc1, 0xf3, 0xf8, 0xa0, 0xfd, 0x44, 0x98, 0x59,
        0x59, 0xfe, 0xc6, 0x46, 0xe2, 0x3e, 0x9a, 0x8a, 0xd3, 0xe9, 0x08, 0xc1, 0x77, 0x39, 0x95, 0x88,
        0x73, 0x32, 0x6d, 0x17, 0x14, 0xfe, 0x1c, 0xe0, 0x83, 0x3e, 0xc7, 0x47, 0xf2, 0x19, 0x5c, 0x5e,
        0x24, 0xd5, 0x54, 0xdd, 0xee, 0xe9, 0xd6, 0xba, 0x7f, 0x1b, 0x3f, 0xb7, 0x92, 0x30, 0x3c, 0xdb,
        0x29, 0x7f, 0x0b, 0x5c, 0xe0, 0xf0, 0x95, 0x19, 0xf6, 0x23, 0xc8, 0xb3, 0xea, 0xf9, 0x76, 0xe4,
        0xc8, 0xf9, 0xc5, 0x17, 0xb5, 0xc2, 0xce, 0xab, 0x63, 0xb2, 0x28, 0x9f, 0x1c, 0x73, 0x63, 0x09,
        0x93, 0x84, 0xb1, 0xcb, 0x46, 0xba, 0x9c, 0xb7, 0x38, 0x36, 0xaf, 0x05, 0xa3, 0x03, 0x1c, 0x55,
        0xfe, 0xc7, 0x54, 0x3d, 0xde, 0xfa, 0x31, 0xec, 0x76, 0x0b, 0x0a, 0x88, 0xd9, 0x1c, 0x73, 0xdf,
        0xfc, 0x7a, 0x2e, 0xdf, 0xc4, 0x99, 0x97, 0xb6, 0xc7, 0x6b, 0x92, 0x79, 0x15, 0xe8, 0x79, 0x0e,
        0xe7, 0x3f, 0xa5, 0x09, 0xdf, 0x5a, 0xd0, 0x5a, 0xb0, 0xe8, 0x6e, 0x58, 0x62, 0x71, 0x89, 0x9a,
        0xee, 0x42, 0xd8, 0x2c, 0x1e, 0x9d, 0xfe, 0xe6, 0x82, 0xec, 0xb1, 0xe8, 0x20, 0x03, 0xaa, 0x37,
        0xfd, 0x88, 0xc5, 0x80, 0xe8, 0xd3, 0x75, 0xac, 0xec, 0x50, 0xe7, 0x35, 0x8e, 0xa6, 0x22, 0xc1,
        0xa7, 0xb9, 0x4e, 0x1e, 0x94, 0x51, 0x59, 0x8e, 0x61, 0x10, 0xd5, 0x7c, 0xd7, 0x4e, 0xc7, 0x22,
        0x53, 0xc7, 0x71, 0x58, 0xf5, 0xd7, 0xc7, 0xc3, 0x60, 0xa1, 0x6a, 0x14, 0xb0, 0x11, 0x13, 0x5e,
        0xf3, 0x5c, 0xe8, 0xd0, 0xca, 0x72, 0xaf, 0x0f, 0x45, 0x9e, 0x15, 0x34, 0x0a, 0x65, 0xdf, 0x6b,
        0x64, 0xc9, 0xdd, 0xb0, 0x28, 0x81, 0xdc, 0x54, 0x7a, 0x6b, 0x68, 0xa4, 0x6e, 0xac, 0xea, 0xb5,
        0x8b, 0xdb, 0xaf, 0x3a, 0xee, 0xd7, 0x99, 0x75, 0xb4, 0x41, 0x2f, 0xe0, 0x25, 0x0b, 0xc6, 0x91,
        0xff, 0xa0, 0x7a, 0x02, 0x0a, 0x96, 0x76, 0x5b, 0xd8, 0x2f, 0x08, 0x0c, 0xc0, 0xc1, 0xa2, 0xd8,
        0x35, 0x78, 0xda, 0x53, 0xd1, 0x5a, 0xe2, 0x89, 0xe0, 0x2c, 0x62, 0xac, 0x76, 0x0c, 0x7f, 0xfa,
        0xe8, 0xe4, 0x1d, 0xbe, 0xb4, 0x9c, 0xf2, 0x2c, 0xa2, 0xf5, 0x11, 0x2f, 0xbe, 0x91, 0x5d, 0xe0,
        0x41, 0xa5, 0x9d, 0x95, 0x3c, 0xed, 0x24, 0x4b, 0x4e, 0x99, 0x2d, 0x78, 0x28, 0xbc, 0x82, 0x0a,
        0x3f, 0x18, 0x90, 0xbf, 0x1c, 0x90, 0x8b, 0x26, 0xe6, 0x7f, 0xdf, 0x57, 0x10, 0xce, 0x0b, 0x84,
        0xaa, 0xde, 0x2a, 0xae, 0xa0, 0xac, 0x8d, 0x69, 0x26, 0x0e, 0xac, 0xee, 0xa7, 0x43, 0x29, 0xc1,
        0x22, 0x84, 0x37, 0xa9, 0x5f, 0x87, 0x8e, 0x12, 0xdf, 0x6b, 0x30, 0xd0, 0x23, 0x93, 0xfc, 0xa2,
        0x06, 0xf6, 0x8b, 0x60, 0xc4, 0x76, 0x1b, 0x78, 0xf8, 0x82, 0x3e, 0x69, 0x5b, 0x75, 0x19, 0x76,
        0xc8, 0x88, 0x0b, 0xa5, 0x3d, 0x3e, 0xa1, 0x1d, 0x73, 0x7f, 0x75, 0x99, 0xb8, 0x6a, 0x0c, 0x00,
        0xfc, 0x06, 0x06, 0x10, 0x8d, 0x27, 0x5c, 0x83, 0xc0, 0x55, 0xeb, 0x22, 0xe1, 0x55, 0x14, 0x3e,
        0xf4, 0x4b, 0x8a, 0xe8, 0xb4, 0x53, 0x78, 0xe2, 0x02, 0x5e, 0x08, 0xe3, 0x96, 0x14, 0x08, 0x90,
        0x23, 0x5c, 0x0d, 0xee, 0x8e, 0xde, 0xc2, 0x08, 0xe9, 0x1c, 0xc5, 0x24, 0x70, 0x72, 0x5e, 0x5f,
        0xa4, 0x12, 0x29, 0x37, 0x54, 0x8c, 0xbd, 0x4a, 0x54, 0x13, 0x2c, 0xf1, 0x2e, 0x4b, 0x6a, 0x05,
        0x6c, 0xa0, 0x62, 0xd1, 0x0c, 0xf2, 0x94, 0x18, 0x0f, 0xca, 0x8f, 0x7a, 0xe4, 0x43, 0x9c, 0x65,
        0x85, 0xea, 0xe4, 0xae, 0x0e, 0x22, 0x13, 0x7b, 0x7e, 0x8d, 0xfb, 0x0b, 0x23, 0x24, 0x61, 0x8d,
        0x23, 0x59, 0xb9, 0x4b, 0x23, 0xdd, 0x80, 0x60, 0x00, 0xa7, 0x6c, 0xb8, 0x8b, 0x9a, 0xce, 0x37,
        0x14, 0x00, 0xa4, 0x31, 0x46, 0x26, 0x58, 0x3a, 0x34, 0xb6, 0xbb, 0xef, 0xd8, 0x27, 0x87, 0xba,
        0x25, 0x29, 0xa4, 0xc6, 0xf9, 0x8a, 0x79, 0x81, 0x8b, 0x98, 0xd4, 0x30, 0xf2, 0x1d, 0xa3, 0xe4,
        0x94, 0x15, 0xfa, 0x08, 0xd0, 0x52, 0x37, 0x3f, 0x5f, 0x59, 0x4e, 0x8b, 0x1a, 0x62, 0x78, 0xd8,
        0x76, 0x1a, 0x00, 0x9c, 0x08, 0x13, 0x0c, 0x05, 0x14, 0x48, 0x5a, 0x39, 0xd9, 0x18, 0x59, 0x50,
        0x5b, 0x52, 0x9e, 0x6d, 0xe3, 0xa2, 0xdc, 0xd4, 0xc0, 0x98, 0xbc, 0x79, 0xce, 0x7e, 0x88, 0x9f,
        0x70, 0xbb, 0x67, 0x9d, 0x6e, 0xa1, 0x5b, 0x71, 0x8a, 0x60, 0xb7, 0xbb, 0x8f, 0x38, 0x7f, 0xb3,
        0x84, 0xe3, 0x55, 0x95, 0x89, 0xd5, 0x8a, 0x44, 0x74, 0x76, 0x7b, 0xe7, 0x59, 0x37, 0x5b, 0x2c,
        0xdf, 0xda, 0xbb, 0x3c, 0x73, 0x45, 0xf7, 0x0f, 0x4d, 0xda, 0x56, 0xa4, 0x9b, 0xdc, 0xaf, 0xa1,
        0xfa, 0x3c, 0x97, 0x57, 0x59, 0xa3, 0x77, 0x4b, 0x4d, 0xc0, 0x9d, 0xe6, 0x20, 0xd2, 0xd0, 0xc0,
        0x14, 0x62, 0x02, 0x3e, 0x7b, 0xc6, 0x91, 0xe1, 0x35, 0xa7, 0x76, 0xac, 0x7f, 0x04, 0x4d, 0x57,
        0xd8, 0x78, 0xd6, 0xbe, 0x72, 0x60, 0x96, 0x33, 0x66, 0x90, 0x12, 0x54, 0x39, 0xdb, 0xb5, 0xe8,
        0x53, 0x07, 0x2f, 0xad, 0x65, 0xfd, 0x58, 0x2a, 0x44, 0xd2, 0x6c, 0x0d, 0xca, 0x3e, 0xa5, 0xbd,
        0xa4, 0x1b, 0x33, 0x07, 0x11, 0x4b, 0x62, 0x77, 0xdf, 0xfa, 0x83, 0xc1, 0xa4, 0x3f, 0xbf, 0xec,
        0xe0, 0x82, 0xed, 0x4a, 0xc4, 0x9f, 0x15, 0x14, 0x63, 0x90, 0x54, 0x15, 0x5a, 0x26, 0x25, 0xc6,
        0x2c, 0x74, 0xd8, 0xf3, 0x70, 0x26, 0xb8, 0x22, 0xef, 0xea, 0x39, 0xb9, 0x20, 0xb3, 0x10, 0x84,
        0x37, 0xa4, 0x30, 0x8c, 0x12, 0x2d, 0x43, 0x3b, 0xbb, 0xf2, 0x79, 0xb6, 0x57, 0x9d, 0x8d, 0x1b,
        0x50, 0xd6, 0x38, 0x16, 0xd8, 0x8e, 0xf7, 0xc4, 0xaa, 0x2b, 0xda, 0x76, 0x2d, 0xce, 0x86, 0x31,
        0x8c, 0x55, 0x1a, 0xe0, 0x5d, 0x9a, 0x4d, 0x73, 0x36, 0x36, 0x60, 0x30, 0x44, 0xda, 0x64, 0x02,
        0xbc, 0x67, 0xbf, 0x22, 0x2c, 0xdf, 0x46, 0xf0, 0x37, 0x0a, 0x34, 0x3f, 0x8c, 0x8e, 0x6a, 0xcd,
        0x1d, 0xa4, 0xf1, 0xa8, 0x1a, 0x99, 0x01, 0xc0, 0x93, 0x6a, 0x47, 0x49, 0x5d, 0x37, 0xbe, 0x67,
        0xb6, 0x15, 0x40, 0x7c, 0xe3, 0x43, 0x5f, 0xe5, 0xfd, 0x09, 0xd4, 0xe1, 0x88, 0xa3, 0x22, 0x9a,
        0x66, 0xbb, 0xf6, 0x92, 0xa7, 0xbe, 0xd8, 0x8d, 0xb6, 0x43, 0xd1, 0xdb, 0x8e, 0xe8, 0x7b, 0x16,
        0x23, 0xee, 0xb7, 0xc5, 0x88, 0x09, 0x44, 0x5b, 0x9a, 0x31, 0x25, 0x30, 0x23, 0x06, 0x09, 0x2a,
        0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x15, 0x31, 0x16, 0x04, 0x14, 0xd3, 0xbf, 0x52, 0xee,
        0xa6, 0x66, 0xf3, 0xb2, 0xa5, 0xf7, 0xfe, 0x5d, 0xe7, 0x1a, 0x28, 0xfc, 0xe7, 0x30, 0xc8, 0xc5,
        0x30, 0x49, 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02,
        0x01, 0x05, 0x00, 0x04, 0x20, 0xef, 0x1a, 0xa6, 0x35, 0x11, 0xaa, 0x97, 0x3b, 0x4b, 0x4e, 0x80,
        0x59, 0x72, 0x35, 0xa6, 0x2f, 0x00, 0xbd, 0x64, 0xab, 0x17, 0x79, 0x23, 0x7a, 0x7f, 0xe4, 0x7c,
        0x08, 0x31, 0x89, 0x2e, 0x62, 0x04, 0x10, 0xf4, 0x83, 0x83, 0x8b, 0x95, 0x85, 0xf7, 0x5f, 0x4d,
        0x11, 0xcc, 0x45, 0xa4, 0xb8, 0xf3, 0x8d, 0x02, 0x02, 0x08, 0x00,
    ];

    auto p = new SChannelProvider;
    auto sc = cast(SChannelContext) p.createContext(SSLContext.Kind.server);
    sc.setIdentityFromPKCS12(testPfxBytes, "test");

    auto s = new TcpServer;
    s.handleAccept = (TcpConnection c)
    {
        auto a = p.createAdapter(sc, c);
        a.handleReadData = (Data d) {
            foreach (ref char ch; cast(char[]) d.mcontents)
                ch = toUpper(ch);
            a.send(d);
        };
        s.close();
    };
    auto port = s.listen(0, "127.0.0.1");

    auto cc = cast(SChannelContext) p.createContext(SSLContext.Kind.client);
    cc.setPeerVerify(SSLContext.Verify.none);
    auto c = new TcpConnection;
    auto a = p.createAdapter(cc, c);
    a.handleConnect = { a.send(Data("hello")); };
    bool ok;
    a.handleReadData = (Data d) {
        assert(cast(string) d.contents == "HELLO");
        ok = true;
        a.disconnect();
    };
    c.connect("127.0.0.1", port);
    socketManager.loop();
    assert(ok);

    // Regression: setHostName should not crash after disconnect.
    a.setHostName("localhost");
}
