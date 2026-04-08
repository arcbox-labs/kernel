// SPDX-License-Identifier: GPL-2.0
/*
 * ArcBox HVC block device driver.
 *
 * Full read-write block device backed by ARM HVC (Hypervisor Call).
 * All I/O traps directly to the VMM which does synchronous pread/pwrite
 * on the host file, bypassing VirtIO queues entirely.
 *
 * SMCCC function IDs (vendor-specific range):
 *   0xC2000000  ARCBOX_HVC_PROBE     -- returns number of block devices
 *   0xC2000001  ARCBOX_HVC_BLK_READ  -- synchronous pread
 *   0xC2000002  ARCBOX_HVC_BLK_WRITE -- synchronous pwrite
 *   0xC2000003  ARCBOX_HVC_BLK_FLUSH -- fsync
 */

#include <linux/blk-mq.h>
#include <linux/blkdev.h>
#include <linux/init.h>
#include <linux/arm-smccc.h>

#define ARCBOX_HVC_PROBE      0xC2000000
#define ARCBOX_HVC_BLK_READ   0xC2000001
#define ARCBOX_HVC_BLK_WRITE  0xC2000002
#define ARCBOX_HVC_BLK_FLUSH  0xC2000003
#define ARCBOX_HVC_SECTOR     512

#define DRIVER_NAME "arcbox_hvc_blk"
#define MAX_DEVICES 8

struct arcbox_hvc_dev {
	struct gendisk *disk;
	struct blk_mq_tag_set tag_set;
	unsigned int idx;
};

static int num_devices;
static struct arcbox_hvc_dev devs[MAX_DEVICES];

static int arcbox_hvc_io(unsigned int idx, sector_t sector,
			 void *buf, unsigned int len, bool write)
{
	struct arm_smccc_res res;
	unsigned long func = write ? ARCBOX_HVC_BLK_WRITE : ARCBOX_HVC_BLK_READ;

	arm_smccc_1_1_hvc(func, idx, sector, virt_to_phys(buf), len,
			  0, 0, 0, &res);

	return (long)res.a0 < 0 ? (int)(long)res.a0 : (int)res.a0;
}

static int arcbox_hvc_flush(unsigned int idx)
{
	struct arm_smccc_res res;

	arm_smccc_1_1_hvc(ARCBOX_HVC_BLK_FLUSH, idx, 0, 0, 0, 0, 0, 0, &res);

	return (long)res.a0 < 0 ? (int)(long)res.a0 : 0;
}

static blk_status_t arcbox_queue_rq(struct blk_mq_hw_ctx *hctx,
				    const struct blk_mq_queue_data *bd)
{
	struct request *rq = bd->rq;
	struct arcbox_hvc_dev *dev = rq->q->queuedata;
	struct bio_vec bvec;
	struct req_iterator iter;
	sector_t sector = blk_rq_pos(rq);
	bool is_write;
	int ret;

	blk_mq_start_request(rq);

	switch (req_op(rq)) {
	case REQ_OP_READ:
		is_write = false;
		break;
	case REQ_OP_WRITE:
		is_write = true;
		break;
	case REQ_OP_FLUSH:
		ret = arcbox_hvc_flush(dev->idx);
		blk_mq_end_request(rq, ret < 0 ? BLK_STS_IOERR : BLK_STS_OK);
		return BLK_STS_OK;
	default:
		blk_mq_end_request(rq, BLK_STS_NOTSUPP);
		return BLK_STS_OK;
	}

	rq_for_each_segment(bvec, rq, iter) {
		void *buf = page_address(bvec.bv_page) + bvec.bv_offset;

		ret = arcbox_hvc_io(dev->idx, sector, buf, bvec.bv_len, is_write);
		if (ret < 0) {
			blk_mq_end_request(rq, BLK_STS_IOERR);
			return BLK_STS_OK;
		}
		sector += bvec.bv_len / ARCBOX_HVC_SECTOR;
	}

	blk_mq_end_request(rq, BLK_STS_OK);
	return BLK_STS_OK;
}

static const struct blk_mq_ops arcbox_mq_ops = {
	.queue_rq = arcbox_queue_rq,
};

static const struct block_device_operations arcbox_fops = {
	.owner = THIS_MODULE,
};

static int arcbox_probe_one(int idx)
{
	struct arcbox_hvc_dev *dev = &devs[idx];
	struct queue_limits lim = {
		.logical_block_size = ARCBOX_HVC_SECTOR,
		.physical_block_size = ARCBOX_HVC_SECTOR,
		.features = BLK_FEAT_WRITE_CACHE,
	};
	struct gendisk *disk;
	int err;

	dev->idx = idx;

	memset(&dev->tag_set, 0, sizeof(dev->tag_set));
	dev->tag_set.ops = &arcbox_mq_ops;
	dev->tag_set.nr_hw_queues = 1;
	dev->tag_set.queue_depth = 64;
	dev->tag_set.numa_node = NUMA_NO_NODE;
	dev->tag_set.flags = BLK_MQ_F_SHOULD_MERGE;

	err = blk_mq_alloc_tag_set(&dev->tag_set);
	if (err)
		return err;

	disk = blk_mq_alloc_disk(&dev->tag_set, &lim, dev);
	if (IS_ERR(disk)) {
		blk_mq_free_tag_set(&dev->tag_set);
		return PTR_ERR(disk);
	}

	dev->disk = disk;
	disk->major = 0;
	disk->first_minor = 0;
	disk->minors = 0;
	disk->fops = &arcbox_fops;
	snprintf(disk->disk_name, DISK_NAME_LEN, "arcboxhvc%d", idx);

	/* Large default capacity — VMM validates sector range. */
	set_capacity(disk, (sector_t)1 << 30);

	err = add_disk(disk);
	if (err) {
		put_disk(disk);
		blk_mq_free_tag_set(&dev->tag_set);
		return err;
	}

	pr_info(DRIVER_NAME ": /dev/%s (device %d, rw)\n", disk->disk_name, idx);
	return 0;
}

static int __init arcbox_hvc_blk_init(void)
{
	struct arm_smccc_res res;
	int i;

	arm_smccc_1_1_hvc(ARCBOX_HVC_PROBE, 0, 0, 0, 0, 0, 0, 0, &res);
	num_devices = (int)res.a0;

	if (num_devices <= 0) {
		pr_info(DRIVER_NAME ": no devices (probe returned %d), skipping\n",
			num_devices);
		return 0;
	}
	if (num_devices > MAX_DEVICES)
		num_devices = MAX_DEVICES;

	pr_info(DRIVER_NAME ": probed %d device(s)\n", num_devices);

	for (i = 0; i < num_devices; i++) {
		if (arcbox_probe_one(i))
			pr_warn(DRIVER_NAME ": failed to init device %d\n", i);
	}
	return 0;
}

static void __exit arcbox_hvc_blk_exit(void)
{
	int i;

	for (i = 0; i < num_devices; i++) {
		if (devs[i].disk) {
			del_gendisk(devs[i].disk);
			put_disk(devs[i].disk);
			blk_mq_free_tag_set(&devs[i].tag_set);
		}
	}
}

module_init(arcbox_hvc_blk_init);
module_exit(arcbox_hvc_blk_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("ArcBox HVC block device (read-write)");
