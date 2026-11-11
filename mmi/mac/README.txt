Đặt vào đây file MẪU: mmi/mac/template.bin
  - Là một file MAC dạng bin 254 byte đã dùng được trên Bullet (ví dụ file 742584C00F06 của kỹ thuật).
  - MAC nằm bên trong file này phải khớp biến MAC_TEMPLATE_MAC trong config.sh.
Kiểm tra giả định "chỉ cần thay MAC" bằng 2 file thật khác nhau:
  python3 mmi/lib/mac_bin.py verify mmi/mac/template.bin 742584C00F06 <file_khác.bin> <MAC_của_file_khác>
