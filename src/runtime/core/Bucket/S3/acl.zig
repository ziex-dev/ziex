// Canned ACLs, from Bun's `src/s3_signing/acl.zig`.
pub const Acl = enum {
    // Owner gets FULL_CONTROL; no one else has access (default).
    private,
    // AllUsers get READ.
    public_read,
    // AllUsers get READ and WRITE.
    public_read_write,
    // Amazon EC2 gets READ to fetch an AMI bundle.
    aws_exec_read,
    // AuthenticatedUsers get READ.
    authenticated_read,
    // Bucket owner gets READ.
    bucket_owner_read,
    // Object and bucket owner both get FULL_CONTROL.
    bucket_owner_full_control,
    log_delivery_write,

    pub fn toString(acl: Acl) []const u8 {
        return switch (acl) {
            .private => "private",
            .public_read => "public-read",
            .public_read_write => "public-read-write",
            .aws_exec_read => "aws-exec-read",
            .authenticated_read => "authenticated-read",
            .bucket_owner_read => "bucket-owner-read",
            .bucket_owner_full_control => "bucket-owner-full-control",
            .log_delivery_write => "log-delivery-write",
        };
    }
};

// From Bun's `src/s3_signing/storage_class.zig`.
pub const StorageClass = enum {
    STANDARD,
    STANDARD_IA,
    INTELLIGENT_TIERING,
    EXPRESS_ONEZONE,
    ONEZONE_IA,
    GLACIER,
    GLACIER_IR,
    REDUCED_REDUNDANCY,
    OUTPOSTS,
    DEEP_ARCHIVE,
    SNOW,

    pub fn toString(class: StorageClass) []const u8 {
        return @tagName(class);
    }
};
