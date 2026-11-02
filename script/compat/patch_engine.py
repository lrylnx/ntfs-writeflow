#!/usr/bin/env python3
"""Patch a build copy; never modify the pinned NTFS-3G submodule."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
p = root / 'libntfs-3g/unix_io.c'
source = p.read_text()
validation = r'''
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOBSD.h>
#include <IOKit/IOKitLib.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
/* Validate the already-open descriptor before reading or writing NTFS data.
 * No environment opt-out: this private driver is only for WriteFlow's helper. */
static int writeflow_check_device(int fd, const char *path) {
    const char *id = getenv("WRITEFLOW_MEDIA_ID");
    const char *size = getenv("WRITEFLOW_MEDIA_BYTES");
    char *end = NULL;
    const char *bsd = NULL;
    if (!strncmp(path, "/dev/disk", 9)) bsd = path + 5;
    else if (!strncmp(path, "/dev/rdisk", 10)) bsd = path + 6;
    if (!id || !size || !bsd) return 0;
    unsigned long long expected = strtoull(id, &end, 10);
    if (!expected || !end || *end) return 0;
    unsigned long long bytes = strtoull(size, &end, 10);
    if (!bytes || !end || *end) return 0;
    /* IOBSDNameMatching uses the block-device BSD name. */
    io_service_t media = IOServiceGetMatchingService(kIOMainPortDefault,
        IOBSDNameMatching(kIOMainPortDefault, 0, bsd));
    if (!media) return 0;
    uint64_t actual = 0, blocks = 0;
    uint32_t blocksize = 0;
    struct stat status;
    CFNumberRef majorNumber = IORegistryEntryCreateCFProperty(media, CFSTR("BSD Major"), kCFAllocatorDefault, 0);
    CFNumberRef minorNumber = IORegistryEntryCreateCFProperty(media, CFSTR("BSD Minor"), kCFAllocatorDefault, 0);
    int majorValue = -1, minorValue = -1;
    int ok = majorNumber && minorNumber
        && CFGetTypeID(majorNumber) == CFNumberGetTypeID()
        && CFGetTypeID(minorNumber) == CFNumberGetTypeID()
        && CFNumberGetValue(majorNumber, kCFNumberIntType, &majorValue)
        && CFNumberGetValue(minorNumber, kCFNumberIntType, &minorValue)
        && IORegistryEntryGetRegistryEntryID(media, &actual) == KERN_SUCCESS
        && actual == expected && fstat(fd, &status) == 0
        && (S_ISCHR(status.st_mode) || S_ISBLK(status.st_mode))
        && major(status.st_rdev) == majorValue && minor(status.st_rdev) == minorValue
        && ioctl(fd, DKIOCGETBLOCKSIZE, &blocksize) == 0
        && ioctl(fd, DKIOCGETBLOCKCOUNT, &blocks) == 0
        && blocksize && blocks <= UINT64_MAX / blocksize && blocks * blocksize == bytes;
    if (majorNumber) CFRelease(majorNumber);
    if (minorNumber) CFRelease(minorNumber);
    IOObjectRelease(media);
    return ok;
}
#endif
'''
anchor = 'static int ntfs_device_unix_io_open(struct ntfs_device *dev, int flags)'
assert source.count(anchor) == 1
source = source.replace(anchor, validation + '\n' + anchor)
anchor = '\n#ifdef HAVE_LINUX_FS_H\n\t\t/* Check whether the device was forced read-only */'
assert source.count(anchor) == 1
source = source.replace(anchor, '''
#ifdef __APPLE__
    if (!writeflow_check_device(DEV_FD(dev), dev->d_name)) {
        close(DEV_FD(dev));
        err = ENXIO;
        goto err_out;
    }
#endif
''' + anchor)
p.write_text(source)
