#!/usr/bin/env python3
"""Tạo file MAC dạng bin (mặc định 254 byte) từ một file MẪU đã biết MAC bên trong.

  mac_bin.py make   <template.bin> <MAC_trong_template> <MAC_mới> <out.bin> [độ_dài]
  mac_bin.py verify <template.bin> <MAC_trong_template> <mẫu_khác.bin> <MAC_của_mẫu_khác>

MAC viết 12 ký tự hex (có hoặc không có dấu ':' '-'). Script tự dò MAC trong file mẫu theo 3 kiểu lưu:
plain (74 25 84 C0 0F 06), word-swapped (25 74 C0 84 06 0F) và reversed (06 0F C0 84 25 74),
rồi thay đúng kiểu đó bằng MAC mới. 'verify' dùng để kiểm tra giả định: vá file mẫu thành MAC của một file
thật khác và so sánh - nếu có byte khác ngoài MAC (ví dụ checksum) sẽ in ra vị trí.
"""
import sys


def mac_bytes(s):
    h = s.replace(":", "").replace("-", "").strip()
    if len(h) != 12:
        raise ValueError("MAC phải có 12 ký tự hex: %r" % s)
    return bytes.fromhex(h)


def variants(b):
    sw = b"".join(b[i + 1:i + 2] + b[i:i + 1] for i in range(0, 6, 2))
    return [("plain", lambda x: x), ("word-swapped", lambda x: b"".join(x[i + 1:i + 2] + x[i:i + 1] for i in range(0, 6, 2))),
            ("reversed", lambda x: x[::-1])]


def patch(data, old_mac, new_mac):
    for name, tf in variants(old_mac):
        old = tf(old_mac)
        if data.count(old) >= 1:
            offs = []
            i = data.find(old)
            while i != -1:
                offs.append(i)
                i = data.find(old, i + 1)
            return name, offs, data.replace(old, tf(new_mac))
    raise ValueError("File mẫu không chứa MAC %s (đã thử kiểu plain / word-swapped / reversed)" % old_mac.hex().upper())


def main(argv):
    if len(argv) < 2 or argv[1] not in ("make", "verify"):
        print(__doc__)
        return 2
    try:
        if argv[1] == "make":
            tpl, tmac, nmac, out = argv[2], argv[3], argv[4], argv[5]
            length = int(argv[6]) if len(argv) > 6 else 254
            data = open(tpl, "rb").read()
            if len(data) != length:
                raise ValueError("File mẫu dài %d byte, cần %d" % (len(data), length))
            name, offs, new = patch(data, mac_bytes(tmac), mac_bytes(nmac))
            open(out, "wb").write(new)
            print("OK: kiểu lưu MAC=%s, offset=%s, file=%s (%d byte)"
                  % (name, ",".join(hex(o) for o in offs), out, len(new)))
        else:
            tpl, tmac, sample, smac = argv[2], argv[3], argv[4], argv[5]
            data, ref = open(tpl, "rb").read(), open(sample, "rb").read()
            name, offs, new = patch(data, mac_bytes(tmac), mac_bytes(smac))
            if len(new) != len(ref):
                raise ValueError("Độ dài khác nhau: mẫu %d, so sánh %d" % (len(new), len(ref)))
            diff = [i for i in range(len(ref)) if new[i] != ref[i]]
            if not diff:
                print("GIỐNG HỆT: chỉ cần thay MAC (kiểu %s, offset %s), không có checksum/trường khác."
                      % (name, ",".join(hex(o) for o in offs)))
            else:
                print("KHÁC %d byte ngoài phần MAC, tại offset: %s" % (len(diff), ", ".join(hex(i) for i in diff[:20])))
                print("=> file có thể chứa checksum/trường phụ thuộc MAC, cần tính thêm.")
                return 1
    except (ValueError, OSError, IndexError) as exc:
        print("LỖI: %s" % exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))