const std = @import("std");
const curl = @import("curl");
const lib = @import("../lib.zig");
const Pubkey = lib.core.Pubkey;
const GossipService = lib.gossip.GossipService;
const ContactInfo = lib.gossip.ContactInfo;
const GossipTable = lib.gossip.GossipTable;
const SlotAndHash = lib.accounts_db.SlotAndHash;
const setReadTimeout = lib.net.setReadTimeout;
const Logger = lib.trace.Logger;
const socket_tag = lib.gossip.socket_tag;
const Hash = lib.core.Hash;

const DOWNLOAD_PROGRESS_UPDATES_NS = 30 * std.time.ns_per_s;

const PeerSnapshotHash = struct {
    contact_info: ContactInfo,
    full_snapshot: SlotAndHash,
    inc_snapshot: ?SlotAndHash,
};

/// downloads full and incremental snapshots from peers found in gossip.
/// note: gossip_service must be running.
pub fn downloadSnapshotsFromGossip(
    allocator: std.mem.Allocator,
    logger: Logger,
    // if null, then we trust any peer for snapshot download
    maybe_trusted_validators: ?std.ArrayList(Pubkey),
    gossip_service: *GossipService,
    output_dir: []const u8,
    min_mb_per_sec: usize,
) !void {
    logger.infof("starting snapshot download with min download speed: {d} MB/s", .{min_mb_per_sec});

    const my_contact_info = gossip_service.my_contact_info;
    const my_pubkey = my_contact_info.pubkey;

    var contact_info_buf: [1_000]ContactInfo = undefined;
    var valid_contacts_buf: [1_000]u8 = undefined;
    @memset(&valid_contacts_buf, 0);

    var available_snapshot_peers = std.ArrayList(PeerSnapshotHash).init(allocator);
    defer available_snapshot_peers.deinit();

    var slow_peer_pubkeys = std.ArrayList(Pubkey).init(allocator);
    defer slow_peer_pubkeys.deinit();

    while (true) {
        std.time.sleep(std.time.ns_per_s * 5); // wait while gossip table updates

        // only hold gossip table lock for this block
        {
            var lg = gossip_service.gossip_table_rw.read();
            defer lg.unlock();
            const table: *const GossipTable = lg.get();

            // find valid contact infos:
            // - not me
            // - shred version matches
            // - rpc socket is enabled
            // - snapshot is available
            var contacts = table.getContactInfos(&contact_info_buf, 0);
            logger.infof("found {d} contacts", .{contacts.len});

            var is_me_count: usize = 0;
            var invalid_shred_version: usize = 0;
            var is_slow_count: usize = 0;
            var no_rpc_count: usize = 0;
            var no_snapshot_hashes_count: usize = 0;

            search_loop: for (contacts) |*ci| {
                const is_me = ci.pubkey.equals(&my_pubkey);
                if (is_me) {
                    is_me_count += 1;
                    continue;
                }

                const matching_shred_version = my_contact_info.shred_version == ci.shred_version or my_contact_info.shred_version == 0;
                if (!matching_shred_version) {
                    invalid_shred_version += 1;
                    continue;
                }
                _ = ci.getSocket(socket_tag.RPC) orelse {
                    no_rpc_count += 1;
                    continue;
                };
                const snapshot_hash = table.get(.{ .SnapshotHashes = ci.pubkey }) orelse {
                    no_snapshot_hashes_count += 1;
                    continue;
                };
                const hashes = snapshot_hash.value.data.SnapshotHashes;

                var max_inc_hash: ?SlotAndHash = null;
                for (hashes.incremental) |inc_hash| {
                    if (max_inc_hash == null or inc_hash.slot > max_inc_hash.?.slot) {
                        max_inc_hash = inc_hash;
                    }
                }

                // dont try to download from a slow peer
                for (slow_peer_pubkeys.items) |slow_peer| {
                    if (slow_peer.equals(&ci.pubkey)) {
                        is_slow_count += 1;
                        continue :search_loop;
                    }
                }

                try available_snapshot_peers.append(.{
                    // NOTE: maybe we need to deep clone here due to arraylist sockets?
                    .contact_info = ci.*,
                    .full_snapshot = hashes.full,
                    .inc_snapshot = max_inc_hash,
                });
            }
            logger.infof("is_me_count: {d}, invalid_shred_version: {d}, is_slow_count: {d}, no_rpc_count: {d}, no_snapshot_hashes_count: {d}", .{
                is_me_count,
                invalid_shred_version,
                is_slow_count,
                no_rpc_count,
                no_snapshot_hashes_count,
            });
            logger.infof("found {d} valid peers for snapshot download...", .{available_snapshot_peers.items.len});
        }

        var trusted_snapshot_hashes = std.AutoHashMap(
            SlotAndHash, // full snapshot hash
            std.AutoHashMap(SlotAndHash, void), // set of incremental snapshots
        ).init(allocator);
        defer trusted_snapshot_hashes.deinit();

        if (maybe_trusted_validators) |trusted_validators| {
            // get the hashes of trusted validators
            for (available_snapshot_peers.items) |*peer| {
                var is_trusted = false;
                for (trusted_validators.items) |trusted_validator| {
                    if (peer.contact_info.pubkey.equals(&trusted_validator)) {
                        is_trusted = true;
                        break;
                    }
                }

                if (is_trusted) {
                    var r = try trusted_snapshot_hashes.getOrPut(peer.full_snapshot);
                    if (peer.inc_snapshot) |inc_snapshot| {
                        if (!r.found_existing) {
                            r.value_ptr.* = std.AutoHashMap(SlotAndHash, void).init(allocator);
                        }
                        try r.value_ptr.put(inc_snapshot, {});
                    }
                }
            }
        }

        for (available_snapshot_peers.items) |peer| {
            const only_trusted_validators = maybe_trusted_validators != null;
            if (only_trusted_validators) {
                // full snapshot must be trusted
                if (trusted_snapshot_hashes.getEntry(peer.full_snapshot)) |entry| {
                    // if we have an incremental snapshot
                    if (peer.inc_snapshot) |inc_snapshot| {
                        // check if the incremental snapshot is trusted
                        if (!entry.value_ptr.contains(inc_snapshot)) {
                            continue;
                        }
                    }
                } else {
                    continue;
                }
            }

            // download the full snapshot
            const snapshot_filename = try std.fmt.allocPrint(allocator, "snapshot-{d}-{s}.{s}", .{
                peer.full_snapshot.slot,
                peer.full_snapshot.hash,
                "tar.zst",
            });
            defer allocator.free(snapshot_filename);

            const rpc_socket = peer.contact_info.getSocket(socket_tag.RPC).?;
            const r = rpc_socket.toString();
            const snapshot_url = try std.fmt.allocPrintZ(allocator, "http://{s}/{s}", .{
                r[0][0..r[1]],
                snapshot_filename,
            });
            defer allocator.free(snapshot_url);

            logger.infof("downloading full_snapshot from: {s}", .{snapshot_url});
            var success = downloadFile(
                allocator,
                logger,
                snapshot_url,
                output_dir,
                snapshot_filename,
                min_mb_per_sec,
            ) catch |err| {
                logger.infof("failed to download full_snapshot: {s}", .{@errorName(err)});
                try slow_peer_pubkeys.append(peer.contact_info.pubkey);
                continue;
            };
            if (!success) {
                logger.infof("peer is too slow, skipping", .{});
                try slow_peer_pubkeys.append(peer.contact_info.pubkey);
                continue;
            }

            // download the incremental snapshot
            // NOTE: PERF: maybe do this in another thread? while downloading the full snapshot
            if (peer.inc_snapshot) |inc_snapshot| {
                const inc_snapshot_filename = try std.fmt.allocPrint(allocator, "incremental-snapshot-{d}-{d}-{s}.{s}", .{
                    peer.full_snapshot.slot,
                    inc_snapshot.slot,
                    inc_snapshot.hash,
                    "tar.zst",
                });
                defer allocator.free(inc_snapshot_filename);

                const inc_snapshot_url = try std.fmt.allocPrintZ(allocator, "http://{s}/{s}", .{
                    r[0][0..r[1]],
                    inc_snapshot_filename,
                });
                defer allocator.free(inc_snapshot_url);

                logger.infof("downloading inc_snapshot from: {s}", .{inc_snapshot_url});
                _ = downloadFile(
                    allocator,
                    logger,
                    inc_snapshot_url,
                    output_dir,
                    inc_snapshot_filename,
                    // NOTE: no min limit (we already downloaded the full snapshot at a good speed so this should be ok)
                    null,
                ) catch |err| {
                    // failure here is ok (for now?)
                    logger.infof("failed to download inc_snapshot: {s}", .{@errorName(err)});
                    return;
                };
            }

            // success
            return;
        }

        // try again
        available_snapshot_peers.clearRetainingCapacity();
    }
}

const DownloadProgress = struct {
    mmap: []align(std.mem.page_size) u8,
    download_size: usize,
    min_mb_per_second: ?usize,
    logger: Logger,

    mb_timer: std.time.Timer,
    bytes_read: usize = 0,
    file_memory_index: usize = 0,
    has_checked_speed: bool = false,

    const Self = @This();

    pub fn init(
        logger: Logger,
        output_dir_str: []const u8,
        filename: []const u8,
        download_size: usize,
        min_mb_per_second: ?usize,
    ) !Self {
        var output_dir = try std.fs.cwd().openDir(output_dir_str, .{});
        var file = try output_dir.createFile(filename, .{ .read = true });
        defer file.close();

        // resize the file
        try file.seekTo(download_size - 1);
        _ = try file.write(&[_]u8{1});
        try file.seekTo(0);

        var file_memory = try std.os.mmap(
            null,
            download_size,
            std.os.PROT.READ | std.os.PROT.WRITE,
            std.os.MAP.SHARED,
            file.handle,
            0,
        );

        return .{
            .logger = logger,
            .mmap = file_memory,
            .download_size = download_size,
            .min_mb_per_second = min_mb_per_second,
            .mb_timer = try std.time.Timer.start(),
        };
    }

    pub fn bufferWriteCallback(ptr: [*c]c_char, size: c_uint, nmemb: c_uint, user_data: *anyopaque) callconv(.C) c_uint {
        const len = size * nmemb;
        var self: *Self = @alignCast(@ptrCast(user_data));
        var typed_data: [*]u8 = @ptrCast(ptr);
        var buf = typed_data[0..len];

        @memcpy(self.mmap[self.file_memory_index..][0..len], buf);
        self.file_memory_index += len;
        self.bytes_read += len;

        const elapsed_ns = self.mb_timer.read();
        if (elapsed_ns > DOWNLOAD_PROGRESS_UPDATES_NS) {
            // each MB
            const mb_read = self.bytes_read / 1024 / 1024;
            if (mb_read == 0) {
                self.logger.infof("download speed is too slow (<1MB/s) -- disconnecting", .{});
                return 0;
            }

            defer {
                self.bytes_read = 0;
                self.mb_timer.reset();
            }
            const elapsed_sec = elapsed_ns / std.time.ns_per_s;
            const ns_per_mb = elapsed_ns / mb_read;
            const mb_left = (self.download_size - self.bytes_read) / 1024 / 1024;
            const time_left_ns = mb_left * ns_per_mb;
            const mb_per_second = mb_read / elapsed_sec;

            self.logger.infof("[download progress]: {d}% done ({d} MB/s) (time left: {d})", .{
                self.bytes_read * 100 / self.download_size,
                mb_per_second,
                std.fmt.fmtDuration(time_left_ns),
            });

            const should_check_speed = self.min_mb_per_second != null and !self.has_checked_speed;
            if (should_check_speed) {
                // dont check again
                self.has_checked_speed = true;
                if (mb_per_second < self.min_mb_per_second.?) {
                    // not fast enough => abort
                    self.logger.infof("download speed is too slow ({d} MB/s) -- disconnecting", .{mb_per_second});
                    return 0;
                } else {
                    self.logger.infof("download speed is ok ({d} MB/s) -- maintaining connection\r", .{mb_per_second});
                }
            }
        }

        return len;
    }
};

fn checkCode(code: curl.libcurl.CURLcode) !void {
    if (code == curl.libcurl.CURLE_OK) {
        return;
    }
    // https://curl.se/libcurl/c/libcurl-errors.html
    std.log.debug("curl err code:{d}, msg:{s}\n", .{ code, curl.libcurl.curl_easy_strerror(code) });
    return error.Unexpected;
}

pub fn setNoBody(self: curl.Easy, no_body: bool) !void {
    try checkCode(curl.libcurl.curl_easy_setopt(self.handle, curl.libcurl.CURLOPT_NOBODY, @as(c_long, @intFromBool(no_body))));
}

pub fn downloadFile(
    allocator: std.mem.Allocator,
    logger: Logger,
    url: [:0]const u8,
    output_dir: []const u8,
    filename: []const u8,
    min_mb_per_second: ?usize,
) !bool {
    var easy = try curl.Easy.init(allocator, .{});
    defer easy.deinit();

    try easy.setUrl(url);
    try easy.setMethod(.HEAD);
    try setNoBody(easy, true);
    var head_resp = easy.perform() catch {
        return error.HeaderRequestFailed;
    };

    var download_size: usize = 0;
    if (try head_resp.getHeader("content-length")) |content_length| {
        download_size = try std.fmt.parseInt(usize, content_length.get(), 10);
    } else {
        logger.debugf("header request didnt have content-length...", .{});
        return error.NoContentLength;
    }

    // timeout will need to be larger
    easy.timeout_ms = std.time.ms_per_hour * 5; // 5 hours is probs too long but its ok
    var download_progress = try DownloadProgress.init(
        logger,
        output_dir,
        filename,
        download_size,
        min_mb_per_second,
    );

    try setNoBody(easy, false); // full download
    try easy.setUrl(url);
    try easy.setMethod(.GET);
    try easy.setWritedata(&download_progress);
    try easy.setWritefunction(DownloadProgress.bufferWriteCallback);

    var resp = easy.perform() catch return false;
    defer resp.deinit();

    const full_download = download_progress.file_memory_index == download_size;
    if (!full_download) {
        // too slow = early exit
        return false;
    }
    return true;
}
