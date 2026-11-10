/++
Password authentication (O5LOGON) in two phases.

Phase 1 sends the user name and client details; the server answers with an
encrypted session key (`AUTH_SESSKEY`), the salt of the user's password
verifier (`AUTH_VFR_DATA`, whose flags give the verifier type) and, for 12c
verifiers, PBKDF2 parameters. The client derives a key from the password,
decrypts the server's session key, makes its own, combines both into a key
that encrypts the password, and sends them in phase 2. The server proves it
knew the verifier by encrypting a known text (`AUTH_SVR_RESPONSE`).

Key derivation:
$(UL
$(LI 11g verifiers: SHA-1(password ‖ salt), padded to an AES-192 key; the
     combined key is MD5 of halves of the XOR of the two session keys;)
$(LI 12c verifiers: PBKDF2-HMAC-SHA512 (the "speedy key"), then SHA-512 → an
     AES-256 key; the combined key is PBKDF2-HMAC-SHA512 of both session keys.)
)

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.protocol.auth;

import dbwire.crypto.aes : Aes, aesBlockSize, cbcDecrypt, cbcEncrypt, pkcs7Pad;
import oracle.exception : ClientException, ProtocolException;
import oracle.protocol.messages : FunctionCode, KeyValue, functionHeader, keyValue;
import oracle.protocol.ttc : TtcWriter;

/// Verifier types (the flags of `AUTH_VFR_DATA`).
enum Verifier : uint
{
    v11g = 0x1B25, /// 11g (SHA-1)
    v11gOther = 0xB152, /// 11g (SHA-1)
    v12c = 0x4815, /// 12c (PBKDF2-HMAC-SHA512)
}

/// Authentication mode bits.
enum AuthMode : uint
{
    logon = 0x1, /// a logon
    withPassword = 0x100, /// the password is sent (phase 2)
}

/// Client details sent in phase 1.
struct ClientDetails
{
    /// Terminal name.
    string terminal = "unknown";
    /// Program name.
    string program;
    /// Machine (host) name.
    string machine;
    /// Process ID.
    string pid;
    /// Operating system user.
    string osUser;
}

/// The phase 1 message.
ubyte[] buildPhase1(string user, const ClientDetails details, ubyte sequence, ubyte fieldVersion) @safe pure
{
    TtcWriter w;
    functionHeader(w, FunctionCode.authPhase1, sequence, fieldVersion);
    w.u8(user.length ? 1 : 0);
    w.ub(user.length);
    w.ub(AuthMode.logon);
    w.u8(1);
    w.ub(5); // key/value pairs
    w.u8(1);
    w.u8(1);
    if (user.length)
        w.clr(cast(const(ubyte)[]) user);
    keyValue(w, "AUTH_TERMINAL", details.terminal);
    keyValue(w, "AUTH_PROGRAM_NM", details.program);
    keyValue(w, "AUTH_MACHINE", details.machine);
    keyValue(w, "AUTH_PID", details.pid);
    keyValue(w, "AUTH_SID", details.osUser);
    return w.data;
}

/// The values phase 2 sends, and what checks the server's answer.
struct Phase2Keys
{
    /// The encrypted client session key (hex).
    string sessionKey;
    /// The encrypted password (hex).
    string password;
    /// The encrypted speedy key (hex; 12c verifiers only).
    string speedyKey;
    /// The combined key, to check the server's response.
    immutable(ubyte)[] comboKey;
}

/++
Computes the phase 2 values from the server's phase 1 answer and the
password. `random` gives the client's random bytes (secure random in use;
fixed bytes in tests).

Throws: `ClientException` for verifier types that are not supported;
`ProtocolException` if the server's values are malformed.
+/
Phase2Keys deriveKeys(const KeyValue[] phase1, scope const(char)[] password,
        scope ubyte[]delegate(size_t) @safe random) @safe
{
    import std.digest.md : MD5;
    import std.digest.sha : SHA1, SHA512;
    import std.digest : digest;
    import dbwire.crypto.pbkdf2 : pbkdf2;

    string get(string key, bool required = true)
    {
        foreach (kv; phase1)
            if (kv.key == key)
                return kv.value;
        if (required)
            throw new ProtocolException("The server's authentication answer has no " ~ key);
        return null;
    }

    uint verifierType;
    foreach (kv; phase1)
        if (kv.key == "AUTH_VFR_DATA")
            verifierType = kv.flags;
    const salt = unhex(get("AUTH_VFR_DATA"));
    const pw = cast(const(ubyte)[]) password;
    immutable(ubyte)[] passwordKey; // 12c: the speedy key
    ubyte[] passwordHash;
    switch (verifierType)
    {
    case Verifier.v12c:
        const iterations = toCount("AUTH_PBKDF2_VGEN_COUNT", get("AUTH_PBKDF2_VGEN_COUNT"));
        passwordKey = (() @trusted => cast(immutable(ubyte)[]) pbkdf2!SHA512(pw, salt ~ cast(
                const(ubyte)[]) "AUTH_PBKDF2_SPEEDY_KEY",
                iterations, 64))();
        passwordHash = digest!SHA512(passwordKey ~ salt)[0 .. 32].dup;
        break;
    case Verifier.v11g:
    case Verifier.v11gOther:
        passwordHash = digest!SHA1(pw ~ salt)[].dup ~ cast(ubyte[])[0, 0, 0, 0];
        break;
    default:
        throw new ClientException("Unsupported password verifier type 0x" ~ hexNumber(
                verifierType)
                ~ " (10g verifiers are not supported: reset the password on a 12c or newer server)");
    }

    const ubyte[aesBlockSize] zero = 0;
    const keyAes = Aes(passwordHash);
    const encryptedServerKey = unhex(get("AUTH_SESSKEY"));
    if (encryptedServerKey.length == 0 || encryptedServerKey.length % aesBlockSize)
        throw new ProtocolException("Invalid AUTH_SESSKEY");
    const serverKey = cbcDecrypt(keyAes, zero, encryptedServerKey);
    const clientKey = random(serverKey.length);
    Phase2Keys k;
    k.sessionKey = hex(cbcEncrypt(keyAes, zero, pkcs7Pad(clientKey))[0 .. clientKey.length]);

    ubyte[] combo;
    if (serverKey.length == 48)
    {
        // 11g: XOR of bytes 16 .. 40, MD5 of the halves
        ubyte[24] mix;
        foreach (i; 0 .. 24)
            mix[i] = serverKey[16 + i] ^ clientKey[16 + i];
        combo = (digest!MD5(mix[0 .. 16])[] ~ digest!MD5(mix[16 .. 24])[])[0 .. 24].dup;
    }
    else if (serverKey.length == 32)
    {
        const text = hex(clientKey[0 .. 32] ~ serverKey[0 .. 32]);
        combo = pbkdf2!SHA512(cast(const(ubyte)[]) text, unhex(get("AUTH_PBKDF2_CSK_SALT")),
                toCount("AUTH_PBKDF2_SDER_COUNT", get("AUTH_PBKDF2_SDER_COUNT")), 32);
    }
    else
        throw new ProtocolException("Invalid server session key length " ~ toText(serverKey.length));

    const comboAes = Aes(combo);
    k.password = hex(cbcEncrypt(comboAes, zero, pkcs7Pad(random(16) ~ pw)));
    if (passwordKey.length)
        k.speedyKey = hex(cbcEncrypt(comboAes, zero, pkcs7Pad(random(16) ~ passwordKey))[0 .. 80]);
    k.comboKey = (() @trusted => cast(immutable(ubyte)[]) combo)();
    return k;
}

/++
The phase 2 message; `proxyClient`: the user of a proxy session (empty:
none); `connectionClass` and `purity` (1 new, 2 self; 0: not sent): DRCP.
+/
ubyte[] buildPhase2(string user, string proxyClient, const Phase2Keys keys, string driverName, string timeZone,
        ubyte sequence, ubyte fieldVersion, string connectionClass = null, ubyte purity = 0) @safe pure
{
    TtcWriter w;
    functionHeader(w, FunctionCode.authPhase2, sequence, fieldVersion);
    const pairs = (keys.speedyKey.length ? 7 : 6) + (proxyClient.length ? 1 : 0) + (connectionClass.length ? 1 : 0)
        + (
                purity ? 1 : 0);
    w.u8(user.length ? 1 : 0);
    w.ub(user.length);
    w.ub(AuthMode.logon | AuthMode.withPassword);
    w.u8(1);
    w.ub(pairs);
    w.u8(1);
    w.u8(1);
    if (user.length)
        w.clr(cast(const(ubyte)[]) user);
    if (proxyClient.length)
        keyValue(w, "PROXY_CLIENT_NAME", proxyClient);
    keyValue(w, "AUTH_SESSKEY", keys.sessionKey, 1);
    if (keys.speedyKey.length)
        keyValue(w, "AUTH_PBKDF2_SPEEDY_KEY", keys.speedyKey);
    keyValue(w, "AUTH_PASSWORD", keys.password);
    keyValue(w, "SESSION_CLIENT_CHARSET", "873");
    keyValue(w, "SESSION_CLIENT_DRIVER_NAME", driverName);
    keyValue(w, "SESSION_CLIENT_VERSION", "0");
    keyValue(w, "AUTH_ALTER_SESSION", "ALTER SESSION SET TIME_ZONE='" ~ timeZone ~ "'\0", 1);
    if (connectionClass.length)
        keyValue(w, "AUTH_KPPL_CONN_CLASS", connectionClass);
    if (purity)
        keyValue(w, "AUTH_KPPL_PURITY", purity == 1 ? "1" : "2", 1);
    return w.data;
}

/++
Checks the server's `AUTH_SVR_RESPONSE`: decrypted with the combined key,
bytes 16 to 32 are "SERVER_TO_CLIENT".

Throws: `ProtocolException` if the server did not prove that it knows the password verifier.
+/
void checkServerResponse(const KeyValue[] phase2, const Phase2Keys keys) @safe
{
    foreach (kv; phase2)
        if (kv.key == "AUTH_SVR_RESPONSE")
        {
            const ubyte[aesBlockSize] zero = 0;
            const aes = Aes(keys.comboKey);
            const encrypted = unhex(kv.value);
            if (encrypted.length == 0 || encrypted.length % aesBlockSize) // cbcDecrypt would throw ClientException
                throw new ProtocolException("The server's authentication response is invalid");
            const plain = cbcDecrypt(aes, zero, encrypted);
            if (plain.length >= 32 && cast(const(char)[]) plain[16 .. 32] == "SERVER_TO_CLIENT")
                return;
            throw new ProtocolException("The server's authentication response is invalid");
        }
    throw new ProtocolException("The server sent no authentication response");
}

/// Upper-case hexadecimal text of `b`.
string hex(scope const(ubyte)[] b) @safe pure nothrow
{
    static immutable digits = "0123456789ABCDEF";
    auto s = new char[2 * b.length];
    foreach (i, x; b)
    {
        s[2 * i] = digits[x >> 4];
        s[2 * i + 1] = digits[x & 15];
    }
    return (() @trusted => cast(string) s)();
}

/// The bytes of hexadecimal text.
ubyte[] unhex(scope const(char)[] s) @safe pure
{
    static int nibble(char c) @safe pure nothrow @nogc
    {
        return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F'
            ? c - 'A' + 10 : -1;
    }

    if (s.length % 2)
        throw new ProtocolException("Odd-length hexadecimal value");
    auto b = new ubyte[s.length / 2];
    foreach (i; 0 .. b.length)
    {
        const hi = nibble(s[2 * i]), lo = nibble(s[2 * i + 1]);
        if (hi < 0 || lo < 0)
            throw new ProtocolException("Invalid hexadecimal value");
        b[i] = cast(ubyte)((hi << 4) | lo);
    }
    return b;
}

/++
The most PBKDF2 iterations the client does for the server: servers send 4096
(`AUTH_PBKDF2_VGEN_COUNT`) and 3 (`AUTH_PBKDF2_SDER_COUNT`); a million
SHA-512 rounds take about a second. More would let anyone who can answer in
the server's place (before the server proved anything) keep the client busy.
+/
enum uint maxPbkdf2Iterations = 1_000_000;

// An iteration count from the server: 1 to maxPbkdf2Iterations.
private uint toCount(string key, string s) @safe pure
{
    import std.conv : ConvException, to;

    uint n;
    try
        n = s.to!uint;
    catch (ConvException)
        throw new ProtocolException("Invalid " ~ key ~ " '" ~ s ~ "'");
    if (n == 0 || n > maxPbkdf2Iterations)
        throw new ProtocolException(
                "The server asked for " ~ s ~ " PBKDF2 iterations (" ~ key ~ "), not 1 to "
                ~ toText(
                    maxPbkdf2Iterations));
    return n;
}

private string hexNumber(uint v) @safe pure
{
    import std.format : format;

    return format("%X", v);
}

private string toText(T)(T v) @safe pure
{
    import std.conv : to;

    return v.to!string;
}

///
@safe unittest
{
    assert(hex([0x01, 0xAB]) == "01AB" && unhex("01ab") == [0x01, 0xAB]);
    ClientDetails d;
    d.program = "p";
    const m = buildPhase1("U", d, 1, 13);
    assert(m[0 .. 3] == [3, 118, 1] && m[3] == 1 && m[4 .. 6] == [1, 1] && m[6 .. 8] == [1, 1]);
}

// Key derivation against vectors computed independently (Python hashlib and the OpenSSL command line)
@safe unittest
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.range : iota;

    ubyte[][] randomValues;
    ubyte[] fixed(size_t n) @safe
    {
        auto v = randomValues[0];
        randomValues = randomValues[1 .. $];
        assert(v.length == n);
        return v;
    }

    // 12c verifier
    randomValues = [iota(0x80, 0xA0).map!(i => cast(ubyte) i).array, new ubyte[16], new ubyte[16]];
    randomValues[1][] = 0xA5;
    randomValues[2][] = 0x5A;
    const p12 = [
        KeyValue("AUTH_SESSKEY", "B3F9F3DC4D64D905B745C34C376077FD34BBFA4073BE13B113EBA1586F5B9578"),
        KeyValue("AUTH_VFR_DATA", "101112131415161718191A1B1C1D1E1F", Verifier.v12c),
        KeyValue("AUTH_PBKDF2_CSK_SALT", "303132333435363738393A3B3C3D3E3F"),
        KeyValue("AUTH_PBKDF2_VGEN_COUNT", "4096"), KeyValue("AUTH_PBKDF2_SDER_COUNT", "3"),
    ];
    const k12 = deriveKeys(p12, "tiger", &fixed);
    assert(k12.sessionKey == "F3321528515500C94E77426C2F463E4EE4AC7EF95CE80A03FFEA9587ED61D12C");
    assert(k12.password == "A56306F1F2B2979B5FB29021E324AF2B39736714B5A07F32BD41D3A2553BF343");
    assert(k12.speedyKey == "CAAD8A20AD5742C6F2D9DD3494AD915AFCCFEC0466C8724D270AAAC6BDC54DF4EF16873A0C375B6E"
            ~ "29340FEA609CD7CE5483FF8F8B48E97E5C94E2F2678B53D6331827C61EFC02314768D426A6D038DF");
    checkServerResponse([
        KeyValue("AUTH_SVR_RESPONSE", "BBE45E0C7FEF449D606FD228BA901385B2BE359AA42CA60C7936BB0EFDDF8BBC")
    ], k12);

    // 11g verifier
    randomValues = [iota(0x90, 0xC0).map!(i => cast(ubyte) i).array, new ubyte[16]];
    randomValues[1][] = 0xA5;
    const p11 = [
        KeyValue("AUTH_SESSKEY", "71A6B0548BB46DB38ECBDA75A8814D3ABB124D5A481C151F575110FC9EFF532285EBA0C79F5D5082"
                ~ "B212DEEEFE9A083F"),
        KeyValue("AUTH_VFR_DATA", "20212223242526272829", Verifier.v11g),
    ];
    const k11 = deriveKeys(p11, "tiger", &fixed);
    assert(k11.sessionKey == "0AC3A6D8368EDEECADD07B81674E5AF685E6397E4328A1B21E5E532EDEC7FB955BBA269D1771C14F"
            ~ "D002FA22538A34A4");
    assert(k11.password == "E1D856931271064FE36B66E188C4D3F05028410705FA540C96927208BF1DD67D");
    assert(k11.speedyKey.length == 0);
}

@safe unittest
{
    import std.exception : assertThrown;

    ubyte[] none(size_t n) @safe
    {
        return new ubyte[n];
    }

    assertThrown!ClientException(deriveKeys([KeyValue("AUTH_VFR_DATA", "00", 0x939)], "x", &none)); // 10g
    assertThrown!ProtocolException(deriveKeys([KeyValue("AUTH_VFR_DATA", "00", Verifier.v11g)], "x", &none));
    assertThrown!ProtocolException(checkServerResponse([
        KeyValue("AUTH_SVR_RESPONSE", "00112233445566778899AABBCCDDEEFF")
    ],
    Phase2Keys("", "", "", new immutable(ubyte)[32])));
}

// PBKDF2 iteration counts from the server: 1 to maxPbkdf2Iterations (#42)
@safe unittest
{
    import std.conv : to;
    import std.exception : assertThrown;

    ubyte[] none(size_t n) @safe
    {
        return new ubyte[n];
    }

    foreach (count; ["0", (maxPbkdf2Iterations + 1).to!string, "4294967295", "x"])
        assertThrown!ProtocolException(deriveKeys([
        KeyValue("AUTH_SESSKEY", "00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF"),
        KeyValue("AUTH_VFR_DATA", "101112131415161718191A1B1C1D1E1F", Verifier.v12c),
        KeyValue("AUTH_PBKDF2_VGEN_COUNT", count),
    ], "x", &none));
    // an authentication response that isn't whole AES blocks
    assertThrown!ProtocolException(checkServerResponse([KeyValue("AUTH_SVR_RESPONSE", "0011")],
            Phase2Keys("", "", "", new immutable(ubyte)[32])));
}
