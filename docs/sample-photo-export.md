# Sample Photo Export Changes

## Muc tieu

Khi cam dien thoai vao Mac, co the keo truc tiep thu muc `samples` sang may. Thu muc nay gom:

- Anh mau `.jpg` da ghi thong tin len anh.
- `samples_log.csv` voi moi anh la mot dong data.
- `samples_log.xlsx`, hien dang ghi dang tab-separated text voi duoi `.xlsx` de Excel/Numbers import du lieu.

## Da thay doi

- Anh mau duoc luu kem metadata render truc tiep len anh.
- Metadata tren anh gom:
  - Ten file anh
  - Sample ID
  - Ten mau
  - Loai mau
  - Thoi gian chup
  - Site
  - Huong manh xam
  - Huong lay mau
  - GPS latitude va longitude
  - Do chinh xac GPS
  - Altitude
  - Heading degree va huong cardinal
  - Dia diem reverse-geocode
- File data bay gio bat dau bang cot `File anh`, nen co the map dong data voi anh ma khong can soi lai noi dung tren anh.
- File data ghi cac cot:
  - File anh
  - Sample-ID
  - Ten mau
  - Loai mau
  - Ngay lay
  - Lat
  - Long
  - GPS_accuracy_m
  - Altitude_m
  - Heading_degree
  - Heading_cardinal
  - Location
  - Site
  - Huong manh xam
  - Huong lay mau
- Cac file `samples_log.csv` cu se duoc migrate sang thu tu cot moi khi app append/export sample data lan tiep theo.

## Ghi chu

- App van luu anh thanh file trong thu muc `samples`, khong nhung binary anh vao database, de viec copy thu muc qua Mac don gian va nhe hon.
- Cac dong cu chua co heading hoac GPS accuracy se de trong cac cot do sau migration.
