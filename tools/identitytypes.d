#!/usr/bin/env dub
/+ dub.sdl:
    name "identitytypes"
    dependency "oracle-native" path=".."
+/
/++
Generates `identityTypes` in `source/oracle/protocol/negotiate.d`: the data
types the server accepts unchanged, in the universal representation. It
connects at the TNS level, sends the protocol message and a data-type message
that lists every type number from 1 to 1023 with an identity conversion, and
keeps the types the server answers with an identity conversion, in the order
of its answer. 27 (in `conversions` instead) and 663 (the describe-information
structure, added separately) are left out. The negotiation runs on a
connection of its own; a second one logs in, only to read the server version.

    tools/identitytypes.d <connection string> <user> <password> [source/oracle/protocol/negotiate.d]

With a file name it replaces the declaration in that file, else it prints it
(`dub run --single tools/identitytypes.d -- ...` where scripts can't be run
directly, e.g. on Windows). The types the server converts instead are listed
on stderr.
+/
module identitytypes;

import core.time : seconds;
import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.file : readText;
static import std.file;
import std.format : format;
import std.stdio;
import std.string : indexOf;
import dbwire.io.backend : IoMode, backendFor;
import dbwire.io.buffer : BufferedReader, StringArena;
import oracle.protocol.negotiate;
import oracle.protocol.tns;
import oracle.protocol.ttc : TtcReader, TtcWriter;
import oracle.connection : Connection;
import oracle.settings : ConnectionOptions;

/// Types `negotiate.d` lists elsewhere.
immutable ushort[] listedElsewhere = [27, 663];

int main(string[] args)
{
    if (args.length < 4 || args.length > 5)
    {
        stderr.writeln("usage: identitytypes <connection string> <user> <password> [negotiate.d]");
        return 2;
    }
    string serverVersion;
    {
        auto conn = new Connection(args[1], args[2], args[3]);
        serverVersion = conn.serverVersion;
        conn.close();
    }
    const options = ConnectionOptions.parse(args[1]);
    const endpoint = options.endpoints[0];
    auto transport = backendFor(IoMode.phobos).connect(endpoint.host, endpoint.port, 10.seconds);
    scope (exit)
        transport.close();
    transport.setTimeouts(10.seconds, 10.seconds);
    auto tns = new TnsStream(transport);
    const connectData = options.connectDescriptor(endpoint, "identitytypes", "localhost", "identitytypes");
    Packet p;
    foreach (attempt; 0 .. 10)
    {
        tns.writePackets(buildConnect(connectData, options.sdu, TnsVersion.endOfResponse));
        p = tns.readPacket();
        if (p.type != PacketType.resend)
            break;
    }
    if (p.type != PacketType.accept)
        throw new Exception("The listener answered with packet type " ~ p.type.to!string ~ ", not ACCEPT");
    const accept = parseAccept(p.bytes);
    tns.largeLengths = true;
    tns.sdu = accept.sdu < 512 ? 512 : accept.sdu;
    tns.endOfResponse = accept.tnsVersion >= TnsVersion.endOfResponse
        && (accept.flags2 & AcceptFlags2.hasEndOfResponse) != 0;
    auto reader = TtcReader(new BufferedReader(tns), new StringArena);

    tns.sendData(buildProtocolMessage("identitytypes"));
    readProtocolResponse(reader);

    TtcWriter w;
    w.u8(MessageType.dataTypes);
    w.u16le(CharsetId.al32utf8);
    w.u16le(CharsetId.al32utf8);
    w.u8(0x01 | 0x02); // multibyte, conversion lengths
    w.clr(clientCompileCaps(tns.endOfResponse));
    w.clr(clientRuntimeCaps());
    foreach (ushort type; 1 .. 1024)
    {
        w.u16be(type);
        w.u16be(type);
        w.u16be(Representation.universal);
        w.u16be(0);
    }
    w.u16be(0);
    tns.sendData(w.data);

    if (reader.u8() != MessageType.dataTypes)
        throw new Exception("Expected the data-type message");
    ushort[] identity;
    for (;;)
    {
        const type = reader.u16be();
        if (type == 0)
            break;
        const conversion = reader.u16be();
        if (conversion == 0)
            continue;
        const representation = reader.u16be();
        reader.u16be();
        if (conversion == type && representation == Representation.universal)
        {
            if (!listedElsewhere.canFind(type))
                identity ~= type;
        }
        else
            stderr.writefln("type %s: conversion to %s, representation %s", type, conversion, representation);
    }

    const declaration = format!"%s\n%s"(docComment(serverVersion, identity.length), arrayLiteral(identity));
    if (args.length == 4)
    {
        write(declaration);
        return 0;
    }
    const text = readText(args[4]);
    const start = text.indexOf("/++\nThe data types the client accepts unchanged");
    const end = start < 0 ? -1 : text.indexOf("\n];\n", start);
    if (end < 0)
        throw new Exception("The declaration of identityTypes wasn't found in " ~ args[4]);
    std.file.write(args[4], text[0 .. start] ~ declaration ~ text[end + 4 .. $]);
    return 0;
}

/// The comment above the declaration.
string docComment(string serverVersion, size_t count)
{
    return format!`/++
The data types the client accepts unchanged, in the universal representation.
Many are internal TTC types the server uses in its own messages: without
them it fails the first call after the negotiation.

Generated by %1$stools/identitytypes.d%1$s from Oracle Database %2$s:
the %3$s types the server accepts with an identity conversion, in the order
of its answer to a request listing every type number from 1 to 1023 that way
(27 is in %1$sconversions%1$s instead, 663 is added separately). Older servers
ignore the types they don't know.
+/`("`", serverVersion, count);
}

/// The declaration, 20 numbers per line.
string arrayLiteral(const ushort[] types)
{
    auto text = appender!string;
    text ~= "private immutable ushort[] identityTypes = [";
    foreach (i, t; types)
    {
        if (i % 20 == 0)
            text ~= "\n   ";
        text ~= " " ~ t.to!string ~ ",";
    }
    text ~= "\n];\n";
    return text[];
}
