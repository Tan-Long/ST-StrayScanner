# Exporting Data

There are two ways of exporting the data from the device. The first way is to connect your phone to a computer with a lightning cable. The other option is through the iOS Files app.

## Exporting Using Cable

To access data collected using Stray Scanner, connect your iPhone or iPad to your computer using a lightning cable. Open Finder.app. Select your device from the sidebar. Click on the "Files" tab beneath your device description. Under "Stray Scanner", you should see one directory per dataset you have collected. Drag these to wherever you want to place them.

![How to access Stray Scanner data](/images/euclid.jpg)
In this image, you can see the two datasets "ac1ed2228f" and "c26b6838a9". These are the folders you should drag to your desired destination.

On Windows, a similar process can be followed, but the device is accessed through iTunes.

## Exporting Through the Files App

In the Files app, under "Browse > On My iPhone > Stray Scanner" you can see a folder for each recorded dataset. You can export a folder by moving it to your iCloud drive or share it with some other app.

New LiDAR video folders are named from the active Sample ID and flag, for example `M-1.1*_video_20260524_121530`. Full ZIP export also normalizes older video folders with `sample_metadata.json` to this Sample ID based naming, groups files by day folders in `ddMMyyyy` format, and names the ZIP by data range, for example `StrayScanner_export_20052026_to_24052026.zip`. Inside each day folder, videos are exported under `01_videos`, sample photos under `02_sample_photos`, and that day's CSV/XLSX sample logs under `03_sample_logs` with names like `samples_log_24052026.csv`; other sample data is exported under `04_sample_data`.
