/*
 * EZP2023+ / EZP2019 Linux SPI Flash Programmer (Native C)
 * Reverse engineered from EZP2023+ Windows driver and software.
 * 
 * Build:
 *   gcc -O2 -Wall -Wextra ezp2023.c $(pkg-config --cflags --libs libusb-1.0) -o ezp2023
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <libusb-1.0/libusb.h>

#define EZP_VID 0x1FC8
static const uint16_t EZP_PIDS[] = {0x310B, 0x310C, 0x310D, 0};

#define EP_DATA_OUT 0x01
#define EP_CMD_OUT  0x02
#define EP_IN       0x82

#define PACKET_SIZE 64
#define CHUNK_SIZE  256
#define TIMEOUT_MS  5000

#define CMD_ERASE   0x02
#define CMD_TRIGGER 0x05
#define CMD_READ    0x07
#define CMD_RESET   0x08
#define CMD_CONNECT 0x09
#define CMD_STATUS  0x0A
#define CMD_WRITE   0x0B

typedef struct {
    libusb_context *ctx;
    libusb_device_handle *handle;
    uint16_t pid;
} ezp_dev_t;

static void ezp_prepare_packet(uint8_t pkt[PACKET_SIZE], uint8_t cmd_id,
                               uint32_t size, uint16_t pagesize,
                               uint16_t proto, uint16_t timeout,
                               uint32_t chip_id, uint32_t flags)
{
    memset(pkt, 0, PACKET_SIZE);
    pkt[1] = cmd_id;
    pkt[2] = proto & 0xFF;
    pkt[3] = (proto >> 8) & 0xFF;
    pkt[4] = (pagesize >> 8) & 0xFF;
    pkt[5] = pagesize & 0xFF;
    pkt[6] = (timeout >> 8) & 0xFF;
    pkt[7] = timeout & 0xFF;
    pkt[8]  = (size >> 24) & 0xFF;
    pkt[9]  = (size >> 16) & 0xFF;
    pkt[10] = (size >> 8) & 0xFF;
    pkt[11] = size & 0xFF;
    pkt[12] = (chip_id >> 24) & 0xFF;
    pkt[13] = (chip_id >> 16) & 0xFF;
    pkt[14] = (chip_id >> 8) & 0xFF;
    pkt[15] = chip_id & 0xFF;
    pkt[28] = (flags >> 24) & 0xFF;
}

static int ezp_send_cmd(ezp_dev_t *dev, const uint8_t *cmd, uint8_t *resp)
{
    int transferred = 0;
    int r = libusb_bulk_transfer(dev->handle, EP_CMD_OUT, (unsigned char *)cmd,
                                 PACKET_SIZE, &transferred, TIMEOUT_MS);
    if (r != 0 || transferred != PACKET_SIZE) {
        libusb_clear_halt(dev->handle, EP_CMD_OUT);
        return -1;
    }

    if (resp != NULL) {
        usleep(50000); /* 50ms wait required by EZP MCU firmware */
        r = libusb_bulk_transfer(dev->handle, EP_IN, resp,
                                 PACKET_SIZE, &transferred, TIMEOUT_MS);
        if (r != 0 || transferred != PACKET_SIZE) {
            libusb_clear_halt(dev->handle, EP_IN);
            return -1;
        }
    }
    return 0;
}

static int ezp_open(ezp_dev_t *dev)
{
    memset(dev, 0, sizeof(*dev));
    if (libusb_init(&dev->ctx) < 0) return -1;

    for (int i = 0; EZP_PIDS[i] != 0; i++) {
        dev->handle = libusb_open_device_with_vid_pid(dev->ctx, EZP_VID, EZP_PIDS[i]);
        if (dev->handle) {
            dev->pid = EZP_PIDS[i];
            break;
        }
    }

    if (!dev->handle) return -2;

    libusb_set_auto_detach_kernel_driver(dev->handle, 1);

    /* Required handshake: Query String Descriptors 1 and 2 */
    uint8_t desc_buf[256];
    libusb_control_transfer(dev->handle, 0x80, 0x06, (0x03 << 8) | 0x01, 0x0409, desc_buf, sizeof(desc_buf), 1000);
    libusb_control_transfer(dev->handle, 0x80, 0x06, (0x03 << 8) | 0x02, 0x0409, desc_buf, sizeof(desc_buf), 1000);

    if (libusb_claim_interface(dev->handle, 0) != 0) {
        libusb_close(dev->handle);
        dev->handle = NULL;
        return -3;
    }

    return 0;
}

static void ezp_close(ezp_dev_t *dev)
{
    if (dev->handle) {
        uint8_t rst[PACKET_SIZE];
        memset(rst, 0, PACKET_SIZE);
        rst[0] = 0x01;
        rst[1] = CMD_RESET;
        ezp_send_cmd(dev, rst, NULL);

        libusb_release_interface(dev->handle, 0);
        libusb_close(dev->handle);
        dev->handle = NULL;
    }
    if (dev->ctx) {
        libusb_exit(dev->ctx);
        dev->ctx = NULL;
    }
}

static int ezp_probe(ezp_dev_t *dev, uint32_t *jedec_id)
{
    uint8_t pkt[PACKET_SIZE];
    uint8_t resp[PACKET_SIZE];

    ezp_prepare_packet(pkt, CMD_CONNECT, 0, 256, 0, 1000, 0, 0);

    /* First probe wakes SPI bus */
    if (ezp_send_cmd(dev, pkt, resp) < 0) return -1;
    usleep(50000);

    /* Second probe returns stable JEDEC ID */
    if (ezp_send_cmd(dev, pkt, resp) < 0) return -1;

    *jedec_id = ((uint32_t)resp[1] << 16) | ((uint32_t)resp[2] << 8) | resp[3];
    return 0;
}

static int ezp_trigger(ezp_dev_t *dev, uint32_t address, bool read_mode)
{
    uint8_t pkt[PACKET_SIZE];
    uint8_t resp[PACKET_SIZE];
    memset(pkt, 0, PACKET_SIZE);
    pkt[1] = CMD_TRIGGER;
    pkt[8]  = (address >> 24) & 0xFF;
    pkt[9]  = (address >> 16) & 0xFF;
    pkt[10] = (address >> 8) & 0xFF;
    pkt[11] = address & 0xFF;
    return ezp_send_cmd(dev, pkt, read_mode ? resp : NULL);
}

static int ezp_poll_status(ezp_dev_t *dev, int retries)
{
    uint8_t pkt[PACKET_SIZE];
    uint8_t resp[PACKET_SIZE];
    memset(pkt, 0, PACKET_SIZE);
    pkt[1] = CMD_STATUS;

    int polls = 0;
    while (retries-- > 0) {
        polls++;
        usleep(30000);
        if (ezp_send_cmd(dev, pkt, resp) == 0) {
            if ((resp[0] & 0x01) == 0 && polls > 1) {
                return 0;
            }
        }
    }
    return -1;
}

static int ezp_read(ezp_dev_t *dev, uint32_t total_size, uint16_t pagesize, uint8_t *buffer)
{
    uint8_t pkt[PACKET_SIZE];
    ezp_prepare_packet(pkt, CMD_READ, total_size, pagesize, 0, 1000, 0, 0);
    if (ezp_send_cmd(dev, pkt, pkt) < 0) return -1;

    if (ezp_trigger(dev, 0, true) < 0) return -1;

    uint32_t received = 0;
    uint8_t chunk[CHUNK_SIZE];
    int transferred = 0;

    while (received < total_size) {
        uint32_t req = total_size - received;
        if (req > CHUNK_SIZE) req = CHUNK_SIZE;

        int r = libusb_bulk_transfer(dev->handle, EP_IN, chunk, CHUNK_SIZE,
                                     &transferred, TIMEOUT_MS);
        if (r != 0) {
            libusb_clear_halt(dev->handle, EP_IN);
            return -1;
        }
        memcpy(buffer + received, chunk, req);
        received += req;

        printf("\rReading: %u / %u bytes (%u%%)", received, total_size, (received * 100) / total_size);
        fflush(stdout);
    }
    printf("\n");
    return 0;
}

static int ezp_write(ezp_dev_t *dev, uint32_t total_size, uint16_t pagesize, const uint8_t *buffer)
{
    uint8_t pkt[PACKET_SIZE];
    ezp_prepare_packet(pkt, CMD_READ, total_size, pagesize, 0, 1000, 0, 0);
    if (ezp_send_cmd(dev, pkt, pkt) < 0) return -1;

    if (ezp_trigger(dev, 0, false) < 0) return -1;

    uint32_t sent = 0;
    int transferred = 0;

    while (sent < total_size) {
        uint32_t chunk_len = total_size - sent;
        if (chunk_len > pagesize) chunk_len = pagesize;

        int r = libusb_bulk_transfer(dev->handle, EP_DATA_OUT, (unsigned char *)buffer + sent,
                                     chunk_len, &transferred, TIMEOUT_MS);
        if (r != 0 || (uint32_t)transferred != chunk_len) {
            libusb_clear_halt(dev->handle, EP_DATA_OUT);
            return -1;
        }
        sent += chunk_len;

        printf("\rWriting: %u / %u bytes (%u%%)", sent, total_size, (sent * 100) / total_size);
        fflush(stdout);
    }
    printf("\n");

    usleep(100000);
    return ezp_poll_status(dev, 500);
}

static int ezp_erase(ezp_dev_t *dev)
{
    uint8_t pkt[PACKET_SIZE];
    ezp_prepare_packet(pkt, CMD_READ, 0, 256, 0, 1000, 0, 0);
    if (ezp_send_cmd(dev, pkt, pkt) < 0) return -1;

    memset(pkt, 0, PACKET_SIZE);
    pkt[0] = 0x01;
    pkt[1] = CMD_ERASE;
    pkt[0x1A] = 0x80;
    pkt[0x1B] = 0x00;

    if (ezp_send_cmd(dev, pkt, NULL) < 0) return -1;

    printf("Erasing flash... (please wait)\n");
    return ezp_poll_status(dev, 2000);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <detect|read <file> <size>|write <file>|erase>\n", argv[0]);
        return 1;
    }

    ezp_dev_t dev;
    int err = ezp_open(&dev);
    if (err != 0) {
        if (err == -2) fprintf(stderr, "EZP programmer not found. Please connect device.\n");
        else if (err == -3) fprintf(stderr, "Failed to claim interface. Check udev permissions.\n");
        else fprintf(stderr, "Failed to initialize USB.\n");
        return 1;
    }
    printf("Connected to EZP programmer (PID: 0x%04X)\n", dev.pid);

    uint32_t jedec = 0;
    if (ezp_probe(&dev, &jedec) == 0) {
        printf("Detected JEDEC ID: 0x%06X (Mfr: 0x%02X, Type: 0x%02X, Cap: 0x%02X)\n",
               jedec, (jedec >> 16) & 0xFF, (jedec >> 8) & 0xFF, jedec & 0xFF);
    } else {
        fprintf(stderr, "Failed to probe chip.\n");
        ezp_close(&dev);
        return 1;
    }

    const char *cmd = argv[1];
    if (strcmp(cmd, "detect") == 0) {
        ezp_close(&dev);
        return 0;
    } else if (strcmp(cmd, "erase") == 0) {
        if (ezp_erase(&dev) == 0) {
            printf("Chip erased successfully.\n");
        } else {
            fprintf(stderr, "Erase failed or timed out.\n");
        }
    } else if (strcmp(cmd, "read") == 0) {
        if (argc < 4) {
            fprintf(stderr, "Usage: %s read <filename> <size_in_bytes>\n", argv[0]);
            ezp_close(&dev);
            return 1;
        }
        const char *fname = argv[2];
        uint32_t size = (uint32_t)strtoul(argv[3], NULL, 0);
        uint8_t *buf = malloc(size);
        if (!buf) {
            fprintf(stderr, "Out of memory\n");
            ezp_close(&dev);
            return 1;
        }
        if (ezp_read(&dev, size, 256, buf) == 0) {
            FILE *f = fopen(fname, "wb");
            if (f) {
                fwrite(buf, 1, size, f);
                fclose(f);
                printf("Saved %u bytes to %s\n", size, fname);
            } else {
                perror("fopen");
            }
        } else {
            fprintf(stderr, "Read failed\n");
        }
        free(buf);
    } else if (strcmp(cmd, "write") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: %s write <filename>\n", argv[0]);
            ezp_close(&dev);
            return 1;
        }
        const char *fname = argv[2];
        FILE *f = fopen(fname, "rb");
        if (!f) {
            perror("fopen");
            ezp_close(&dev);
            return 1;
        }
        fseek(f, 0, SEEK_END);
        long sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        uint8_t *buf = malloc(sz);
        if (!buf || fread(buf, 1, sz, f) != (size_t)sz) {
            fprintf(stderr, "File read error\n");
            fclose(f);
            free(buf);
            ezp_close(&dev);
            return 1;
        }
        fclose(f);

        if (ezp_write(&dev, (uint32_t)sz, 256, buf) == 0) {
            printf("Write complete!\n");
        } else {
            fprintf(stderr, "Write failed\n");
        }
        free(buf);
    }

    ezp_close(&dev);
    return 0;
}
