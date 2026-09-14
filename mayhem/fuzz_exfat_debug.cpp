/*
 * In-process libFuzzer harness for libexfat.
 *
 * The original `exfat-debug` harness merely forwarded fuzz bytes to exfat_debug() — a printf-style
 * logging function — which exercised none of the exFAT parser. This drives the REAL code path: it
 * writes the fuzz input to a scratch image, mounts it read-only via exfat_mount(), then walks the
 * directory tree (lookup/opendir/readdir/get_name/stat, reading file contents), then unmounts. This
 * is the same parsing surface dumpexfat/fsck reach, exercised entirely in-process.
 *
 * NB: libexfat/compiler.h #errors unless __STDC_VERSION__ >= C99, so this file is COMPILED AS C
 * (clang -x c) even though it keeps the historical .cpp name (harness-parity with the original).
 * The extern "C" wrappers are guarded so it stays valid under a C++ compiler too.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>

#ifdef __cplusplus
extern "C" {
#endif
#include "exfat.h"
#ifdef __cplusplus
}
#endif

static const char* kImg = "/tmp/exfat_fuzz_input.img";

static void walk(struct exfat* ef, struct exfat_node* dir, int depth)
{
	struct exfat_iterator it;
	struct exfat_node* node;

	if (depth > 8)
		return;
	if (exfat_opendir(ef, dir, &it) != 0)
		return;
	while ((node = exfat_readdir(&it)) != NULL)
	{
		char name[EXFAT_UTF8_NAME_BUFFER_MAX];
		struct stat stbuf;

		exfat_get_name(node, name);
		exfat_stat(ef, node, &stbuf);
		if (node->attrib & EXFAT_ATTRIB_DIR)
		{
			walk(ef, node, depth + 1);
		}
		else
		{
			char buf[512];
			off_t off = 0;
			ssize_t n;
			int reads = 0;
			while ((n = exfat_generic_pread(ef, node, buf, sizeof(buf), off)) > 0
					&& reads++ < 64)
				off += n;
		}
		exfat_put_node(ef, node);
	}
	exfat_closedir(ef, &it);
}

int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
	int fd;
	struct exfat ef;
	struct exfat_node* root;

	fd = open(kImg, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		return 0;
	if (write(fd, data, size) != (ssize_t) size)
	{
		close(fd);
		return 0;
	}
	close(fd);

	if (exfat_mount(&ef, kImg, "ro") != 0)
		return 0;

	exfat_get_label(&ef);

	if (exfat_lookup(&ef, &root, "/") == 0)
	{
		walk(&ef, root, 0);
		exfat_put_node(&ef, root);
	}

	exfat_unmount(&ef);
	return 0;
}
