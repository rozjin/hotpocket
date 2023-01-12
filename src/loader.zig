const std = @import("std");
const heap = std.heap;
const fs = std.fs;
const io = std.io;
const log = std.log;
const mem = std.mem;
const zip = std.compress.deflate;

const Dir = fs.Dir;
const File = fs.File;

const jReaderDef = @import("reader.zig");
const jClassDef = @import("class.zig");
const jParserDef = @import("parser.zig");
const rangeDef = @import("range.zig");

const range = rangeDef.range;

const Reader = jReaderDef.Reader;
const JClass = jClassDef.JClass;
const JClassParser = jParserDef.JClassParser;

pub const JLoader = struct {
    const Compress = struct {
        const None: u16 = 0;
        const Deflate: u16 = 8;
    };

    const JarHeaderMagic: u32 = 0x04034b50;
    const JarHeader = extern struct {
        magic: u32 align(1),
        version: u16 align(1),
        flag: u16 align(1),
        compress: u16 align(1),
        modTime: u16 align(1),
        modDate: u16 align(1),

        crc: u32 align(1),
        cmpSz: u32 align(1),
        dmpSz: u32 align(1),
        name_len: u16 align(1),
        extra_len: u16 align(1),

        pub fn size(self: *const JarHeader) usize {
            return @sizeOf(JarHeader) + self.name_len + self.extra_len;
        }
    };

    const JarRecordMagic: u32 = 0x02014b50;
    const JarRecordMax: u16 = 65535;
    const JarRecord = extern struct {
        magic: u32 align(1),
        madeBy: u16 align(1),
        version: u16 align(1),
        flag: u16 align(1),
        compress: u16 align(1),
        modTime: u16 align(1),
        modDate: u16 align(1),

        crc: u32 align(1),
        cmpSz: u32 align(1),
        dmpSz: u32 align(1),
        name_len: u16 align(1),
        extra_len: u16 align(1),
        comment_len: u16 align(1),
        disk: u16 align(1),
        iAttr: u16 align(1),
        eAttr: u32 align(1),
        off: u32 align(1),

        pub fn size(self: *const JarRecord) usize {
            return @sizeOf(JarRecord) + self.name_len + self.extra_len + self.comment_len;
        }
    };

    const JarEndMagic: u32 = 0x06054b50;
    const JarEnd = extern struct {
        magic: u32 align(1),
        n_disk: u16 align(1),
        s_disk: u16 align(1),
        n_records: u16 align(1),
        t_records: u16 align(1),
        size: u32 align(1),
        off: u32 align(1),
        comment_len: u16 align(1),
    };

    parser: JClassParser = undefined,
    arena: heap.ArenaAllocator = undefined,

    const Self = @This();

    pub fn init() Self {
        var arena = heap.ArenaAllocator
                .init(heap.page_allocator);

        return Self {
            .parser = JClassParser.init(),
            .arena = arena,
        };
    }

    pub fn loadClass(self: *Self, class_path: []const u8) !JClass {
        const allocator = self.arena.allocator();

        var class: File = try fs.openFileAbsolute(class_path, .{});
        var classtat: File.Stat = try class.stat();
        var classize: usize = classtat.size;

        var buf = try allocator.alloc(u8, classize);
        defer allocator.free(buf);

        _ = try class.read(buf);

        return self.parser.parseClass(buf);
    }

    pub fn loadJars(self: *Self, jars: [][]const u8) ![]JClass {
        const allocator = self.arena.allocator();

        var jarClasses = std.ArrayList(JClass).init(allocator);
        defer jarClasses.deinit();

        for (jars) |jar| {
            var classes: []JClass = try self.loadJar(jar);
            try jarClasses.appendSlice(classes);
        }

        return jarClasses.toOwnedSlice();
    }

    fn loadJar(self: *Self, jar_path: []const u8) ![]JClass {
        var dir: Dir = fs.cwd();
        var jar: File = try dir.openFile(jar_path, .{});
        var jarStat: File.Stat = try jar.stat();
        var jarSize: usize = jarStat.size;

        if (jarSize < 22) {
            return error.JarUnderflow;
        }

        const allocator = self.arena.allocator();

        var buf = try allocator.alloc(u8, jarSize);
        defer allocator.free(buf);

        _ = try jar.read(buf);

        var reader = Reader.init(buf);
        var eocd: JarEnd = try reader.readEOF(JarEnd);
        if (eocd.magic != JarEndMagic) {
            log.err("[L] Bad magic number {x}", .{eocd.magic});
            return error.JarBadMagicNumber;
        }

        var classes = std.ArrayList(JClass).init(allocator);
        defer classes.deinit();

        var recordPos: usize = eocd.off;
        for (range(eocd.t_records)) |_| {
            var record: JarRecord = try reader.readPos(recordPos, JarRecord);
            var header: JarHeader = try reader.readPos(record.off, JarHeader);

            if (record.magic != JarRecordMagic or
                header.magic != JarHeaderMagic) {
                break;
            }

            var file_name = try reader.readBytesPos(recordPos + @sizeOf(JarRecord), record.name_len);
            if (record.cmpSz == 0 or
                record.dmpSz == 0 or
                !mem.endsWith(u8, file_name, ".class")) {
                recordPos = recordPos + record.size();
                continue;
            }            

            log.info("[L] Loading class: {s}", .{ file_name });

            switch (record.compress) {
                Compress.None => {
                    var classBuf = try reader.readBytesPos(
                        record.off + header.size(),
                        record.dmpSz
                    );
                    
                    var class: JClass = try self.parser.parseClass(classBuf);
                    try classes.append(class);
                },

                Compress.Deflate => {
                    var classCmpBuf = try reader.readBytesPos(
                        record.off + header.size(),
                        record.cmpSz
                    );

                    var classCmpStream = io.fixedBufferStream(classCmpBuf);
                    var classCmpReader = classCmpStream.reader();
                    var classCmpInf = try zip.decompressor(allocator, classCmpReader, null);

                    var classDmpBuf = try allocator.alloc(u8, record.dmpSz);
                    defer allocator.free(classDmpBuf);
                    var classDmpReader = classCmpInf.reader();
                    _ = try classDmpReader.read(classDmpBuf);

                    var class: JClass = try self.parser
                                .parseClass(classDmpBuf);
                    try classes.append(class);
                },

                else => log.err("[L] Invalid ZIP Compression.", .{})
            }

            recordPos = recordPos + record.size();
        }

        return classes.toOwnedSlice();
    }
};