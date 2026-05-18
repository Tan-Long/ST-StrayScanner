# Sample Photo Export Changes

## Muc tieu

Khi cam dien thoai vao Mac, co the keo truc tiep thu muc `samples` sang may. Thu muc nay gom:

- Anh mau `.jpg` da ghi thong tin len anh.
- `samples_log.csv` voi moi anh la mot dong data.
- `samples_log.xlsx`, hien dang ghi dang tab-separated text voi duoi `.xlsx` de Excel/Numbers import du lieu.

## Da thay doi

- Anh mau duoc luu kem metadata render truc tiep len anh.
- Man hinh chup sample bo truong `Ten mau`; chi giu `Sample ID` de dinh danh anh/data.
- Man hinh chup sample co nut flag `*`; flag nay duoc ghi len anh, file data va duoc dung tiep cho thu muc video.
- Mot `Sample ID` se giu nguyen cho toi khi co du 2 anh `Upslope` va `Downslope`; sau do app moi tang sang Sample ID tiep theo.
- Ten file anh gom Sample ID, flag neu co, huong lay mau va timestamp, vi du `M-1.1*_Upslope_20260518_094500.jpg` va `M-1.1*_Downslope_20260518_094700.jpg`.
- `Loai mau` la nut chon rieng `Dia y` / `Khong dia y`, khong tu dong lien ket vao `Sample ID`.
- `Site` duoc dong bo tu GPS/reverse-geocode; neu chua co dia chi reverse-geocode thi hien toa do GPS tam thoi.
- Neu GPS khong cap nhat duoc, `Site` tu dien site GPS gan nhat da luu; neu may chua tung co GPS thi ghi `Khong co GPS` de file data khong bi trong.
- `Huong lay mau` la nut chon rieng `Upslope` / `Downslope`.
- `Huong camera nhin vao cay` va `Huong manh xam` duoc cap nhat theo heading realtime cua camera streaming; huong manh xam la huong nguoc lai voi huong camera, tuc huong be mat di ra moi truong.
- Simulator co mock camera de xem UI va tao anh/data gia khi khong co iPhone.
- Sau khi chup sample, app luu `Sample ID` hien tai de man hinh quay video tu dong gan vao ten thu muc video, vi du `cay_0001_1805_M-1.1*` neu sample co flag.
- Moi thu muc video co them `sample_metadata.json` de map nguoc ve `Sample ID`, flag, loai mau va site.
- Metadata tren anh gom:
  - Ten file anh
  - Sample ID
  - Flag
  - Loai mau
  - Thoi gian chup
  - Site
  - Huong camera nhin vao cay
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
  - Flag
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
  - Huong camera nhin vao cay
  - Huong manh xam
  - Huong lay mau
- Cac file `samples_log.csv` cu se duoc migrate sang thu tu cot moi khi app append/export sample data lan tiep theo.

## Ghi chu

- App van luu anh thanh file trong thu muc `samples`, khong nhung binary anh vao database, de viec copy thu muc qua Mac don gian va nhe hon.
- `Heading_degree` va `Heading_cardinal` la huong manh xam huong ra moi truong; cot `Huong camera nhin vao cay` luu huong camera dang chieu vao cay.
- Cac dong cu chua co heading hoac GPS accuracy se de trong cac cot do sau migration.
