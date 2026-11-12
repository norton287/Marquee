#!/bin/bash
# Generates tool/media: a 60s clip with two audio tracks, a subtitle track and
# chapters, plus an HLS copy that stands in for a server transcode.
set -e
cd "$(dirname "$0")" && mkdir -p media/hls && cd media
printf '1\n00:00:01,000 --> 00:00:58,000\nSUBTITLE TRACK ON\n' > subs.srt
printf ';FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1\nSTART=0\nEND=20\ntitle=Opening\n[CHAPTER]\nTIMEBASE=1/1\nSTART=20\nEND=40\ntitle=Middle\n[CHAPTER]\nTIMEBASE=1/1\nSTART=40\nEND=60\ntitle=Finale\n' > ch.txt
ffmpeg -v error -y -f lavfi -i "testsrc2=size=1280x720:rate=24:duration=60" \
  -f lavfi -i "sine=frequency=440:duration=60" -f lavfi -i "sine=frequency=880:duration=60" \
  -i subs.srt -i ch.txt -map 0 -map 1 -map 2 -map 3 -map_metadata 4 \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -c:s srt \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=spa -metadata:s:s:0 language=eng movie.mkv
ffmpeg -v error -y -i movie.mkv -map 0:v -map 0:a:0 \
  -vf "scale=640:360,drawtext=text='TRANSCODED':fontsize=40:fontcolor=white:x=20:y=20" \
  -c:v libx264 -preset ultrafast -c:a aac -f hls -hls_time 4 -hls_playlist_type vod hls/main.m3u8
