const std = @import("std");
const fs = std.fs;
const io = std.io;
const log = std.log;
const mem = std.mem;
const zip = std.compress.deflate;

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
    const JarHeader = packed struct {
        magic: u32,
        version: u16,
        flag: u16,
        compress: u16,
        modTime: u16,
        modDate: u16,

        crc: u32,
        cmpSz: u32,
        dmpSz: u32,
        name_len: u16,
        extra_len: u16,

        pub fn size(self: *const JarHeader) usize {
            return @sizeOf(JarHeader) + self.name_len + self.extra_len;
        }
    };

    const JarRecordMagic: u32 = 0x02014b50;
    const JarRecordMax: u16 = 65535;
    const JarRecord = packed struct {
        magic: u32,
        madeBy: u16,
        version: u16,
        flag: u16,
        compress: u16,
        modTime: u16,
        modDate: u16,

        crc: u32,
        cmpSz: u32,
        dmpSz: u32,
        name_len: u16,
        extra_len: u16,
        comment_len: u16,
        disk: u16,
        iAttr: u16,
        eAttr: u32,
        off: u32,

        pub fn size(self: *const JarRecord) usize {
            return @sizeOf(JarRecord) + self.name_len + self.extra_len + self.comment_len;
        }
    };

    const JarEndMagic: u32 = 0x06054b50;
    const JarEnd = packed struct {
        magic: u32,
        n_disk: u16,
        s_disk: u16,
        n_records: u16,
        t_records: u16,
        size: u32,
        off: u32,
        comment_len: u16
    };

    parser: JClassParser = undefined,
    arena: std.heap.ArenaAllocator = undefined,

    const Self = @This();

    pub fn init() Self {
        return Self {
            .parser = JClassParser.init(),
            .arena = std.heap.ArenaAllocator
                .init(std.heap.page_allocator)
        };
    }

    fn allocator(self: *Self) *std.mem.Allocator {
        return &self.arena.allocator;
    }

    pub fn loadClass(self: *Self, class_path: []const u8) !JClass {
        var class: File = try fs.openFileAbsolute(class_path, .{});
        var classtat: File.Stat = try class.stat();
        var classize: usize = classtat.size;

        var buf = try self.allocator().alloc(u8, classize);
        defer self.allocator().free(buf);

        _ = try class.read(buf);

        return self.parser.parseClass(buf);
    }

    pub fn loadJars(self: *Self, jars: [][]const u8) ![]JClass {
        var jarClasses = std.ArrayList(JClass).init(self.allocator());
        defer jarClasses.deinit();

        for (jars) |jar| {
            var classes: []JClass = try self.loadJar(jar);
            try jarClasses.appendSlice(classes);
        }

        return jarClasses.toOwnedSlice();
    }

    fn loadJar(self: *Self, jar_path: []const u8) ![]JClass {
        var jar: File = try fs.openFileAbsolute(jar_path, .{});
        var jarstat: File.Stat = try jar.stat();
        var jarsize: usize = jarstat.size;

        if (jarsize < 22) {
            return error.JarUnderflow;
        }

        var buf = try self.allocator().alloc(u8, jarsize);
        defer self.allocator().free(buf);

        _ = try jar.read(buf);

        var reader = Reader.init(buf);
        var eocd: JarEnd = try reader.readEof(JarEnd);
        if (eocd.magic != JarEndMagic) {
            log.err("[L] Bad magic number {x}", .{eocd.magic});
            return error.JarBadMagicNumber;
        }

        var classes = std.ArrayList(JClass).init(self.allocator());
        defer classes.deinit();

        var recordPos: usize = eocd.off;
        for (range(eocd.t_records)) |_, i| {
            var record: JarRecord = try reader.readPos(recordPos, JarRecord);
            var header: JarHeader = try reader.readPos(record.off, JarHeader);

            if (record.magic != JarRecordMagic or
                header.magic != JarHeaderMagic) {
                break;
            }

            var file_name = try reader.readBytesPos(record.off + @sizeOf(JarHeader), header.name_len);

            if (record.cmpSz == 0 or
                record.dmpSz == 0 or
                !mem.endsWith(u8, file_name, ".class")) {
                recordPos = recordPos + record.size();
                continue;
            }            

            switch (header.compress) {
                Compress.None => {
                    var classBuf = try reader.readBytesPos(
                        record.off + header.size(),
                        header.dmpSz
                    );
                    var class: JClass = try self.parser
                                .parseClass(classBuf);
                    try classes.append(class);
                },

                Compress.Deflate => {
                    var classCmpBuf = try reader.readBytesPos(
                        record.off + header.size(),
                        header.cmpSz
                    );

                    var classDmpReader = io.fixedBufferStream(classCmpBuf).reader();
                    var classDmpSlice = try self.allocator().alloc(u8, 32 * 1024);
                    defer self.allocator().free(classDmpSlice);
                    var classDmpInflater = zip.inflateStream(classDmpReader, classDmpSlice);

                    var classDmpBuf = try self.allocator().alloc(u8, record.dmpSz);
                    defer self.allocator().free(classDmpBuf);
                    _ = try classDmpInflater.read(classDmpBuf);

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