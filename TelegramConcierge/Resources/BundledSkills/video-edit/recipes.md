# ffmpeg Recipes

Reference cookbook for the video-edit skill. Read the section you need; adapt paths, timestamps, and parameters to the actual task.

## Inspect

```bash
ffprobe -v error \
  -show_entries format=duration:stream=index,codec_type,codec_name,width,height,avg_frame_rate,pix_fmt,sample_rate,channels \
  -of json input.mp4
```

Duration only:

```bash
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 input.mp4
```

## Cuts

Fast keyframe trim, no re-encode (may start/end slightly off the requested frame):

```bash
ffmpeg -ss 00:01:30 -i input.mp4 -t 00:00:45 -map 0 -c copy -avoid_negative_ts make_zero output.mp4
```

Frame-accurate trim, re-encoded:

```bash
ffmpeg -i input.mp4 -ss 00:01:30 -t 00:00:45 \
  -map 0:v:0 -map '0:a?' \
  -c:v libx264 -crf 18 -preset medium -pix_fmt yuv420p \
  -c:a aac -b:a 192k -movflags +faststart output.mp4
```

Remove audio:

```bash
ffmpeg -i input.mp4 -map 0:v:0 -c:v copy -an output.mp4
```

Extract one frame:

```bash
ffmpeg -ss 00:00:30 -i input.mp4 -frames:v 1 -q:v 2 frame.jpg
```

## Join Clips

For clips with identical codec, resolution, frame rate, pixel format, and audio layout, use the concat demuxer:

```text
file '/absolute/path/clip1.mp4'
file '/absolute/path/clip2.mp4'
file '/absolute/path/clip3.mp4'
```

```bash
ffmpeg -f concat -safe 0 -i list.txt -c copy output.mp4
```

If clips differ, normalize each clip first, then concat the normalized files with `-c copy`:

```bash
ffmpeg -i clip1.mp4 \
  -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=30,format=yuv420p" \
  -c:v libx264 -crf 20 -preset medium -c:a aac -ar 48000 -ac 2 norm1.mp4
```

## Resize, Crop, Rotate

Resize to 720p preserving aspect ratio and even dimensions:

```bash
ffmpeg -i input.mp4 -map 0:v:0 -map '0:a?' \
  -vf "scale=-2:720" \
  -c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p \
  -c:a aac -b:a 192k -movflags +faststart output.mp4
```

Crop:

```bash
ffmpeg -i input.mp4 -map 0:v:0 -map '0:a?' \
  -vf "crop=1280:720:0:0" \
  -c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p \
  -c:a aac -b:a 192k output.mp4
```

Rotate or flip (`transpose=1` is 90° clockwise; `transpose=2` is 90° counterclockwise):

```bash
ffmpeg -i input.mp4 -map 0:v:0 -map '0:a?' -vf "transpose=1" -c:v libx264 -crf 20 -pix_fmt yuv420p -c:a aac output.mp4
ffmpeg -i input.mp4 -map 0:v:0 -map '0:a?' -vf "hflip" -c:v libx264 -crf 20 -pix_fmt yuv420p -c:a aac output.mp4
```

## Compress Or Convert

Compatible MP4:

```bash
ffmpeg -i input.mov -map 0:v:0 -map '0:a?' \
  -c:v libx264 -crf 22 -preset medium -pix_fmt yuv420p \
  -c:a aac -b:a 160k -movflags +faststart output.mp4
```

Container change only, when codecs are already compatible:

```bash
ffmpeg -i input.mov -map 0 -c copy output.mp4
```

If stream copy fails or the result does not play where needed, re-encode.

## Speed Changes

Whole clip, 2x faster:

```bash
ffmpeg -i input.mp4 -filter_complex \
  "[0:v]setpts=0.5*PTS[v];[0:a]atempo=2.0[a]" \
  -map "[v]" -map "[a]" \
  -c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p \
  -c:a aac -b:a 192k output.mp4
```

Half speed: `setpts=2.0*PTS` and `atempo=0.5`. If there is no audio, omit the audio filter and use `-an`. Chain `atempo` beyond the 0.5–2.0 range.

Selective slow motion: trim segments, reset timestamps after every `trim`/`atrim`, retime the selected segment, concat:

```bash
ffmpeg -i input.mp4 -filter_complex \
  "[0:v]trim=0:4,setpts=PTS-STARTPTS[v0]; \
   [0:v]trim=4:5,setpts=4.0*(PTS-STARTPTS)[v1]; \
   [0:v]trim=5:10,setpts=PTS-STARTPTS[v2]; \
   [v0][v1][v2]concat=n=3:v=1:a=0[v]; \
   [0:a]atrim=0:4,asetpts=PTS-STARTPTS[a0]; \
   [0:a]atrim=4:5,atempo=0.5,atempo=0.5,asetpts=PTS-STARTPTS[a1]; \
   [0:a]atrim=5:10,asetpts=PTS-STARTPTS[a2]; \
   [a0][a1][a2]concat=n=3:v=0:a=1[a]" \
  -map "[v]" -map "[a]" \
  -c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p \
  -c:a aac -b:a 192k output.mp4
```

For silent input, use only the video chains and add `-an`.

Reverse short clips (buffers in memory — split long clips first):

```bash
ffmpeg -i input.mp4 -vf reverse -af areverse -c:v libx264 -crf 20 -pix_fmt yuv420p -c:a aac output.mp4
```

## Audio

Extract audio:

```bash
ffmpeg -i input.mp4 -vn -c:a copy output.m4a
ffmpeg -i input.mp4 -vn -c:a libmp3lame -b:a 192k output.mp3
```

Replace original audio:

```bash
ffmpeg -i video.mp4 -i new_audio.mp3 \
  -map 0:v:0 -map 1:a:0 \
  -c:v copy -c:a aac -b:a 192k -shortest output.mp4
```

Mix original audio with background music (music under speech: 0.15–0.35):

```bash
ffmpeg -i video.mp4 -i music.mp3 -filter_complex \
  "[0:a]volume=1.0[orig];[1:a]volume=0.25[music];[orig][music]amix=inputs=2:duration=first:dropout_transition=2[a]" \
  -map 0:v:0 -map "[a]" -c:v copy -c:a aac -b:a 192k output.mp4
```

Fade music in/out before mixing (fade-out start = duration − fade length):

```bash
ffmpeg -i video.mp4 -i music.mp3 -filter_complex \
  "[1:a]afade=t=in:st=0:d=2,afade=t=out:st=58:d=2,volume=0.25[music];[0:a][music]amix=inputs=2:duration=first[a]" \
  -map 0:v:0 -map "[a]" -c:v copy -c:a aac -b:a 192k output.mp4
```

Mute a segment:

```bash
ffmpeg -i input.mp4 -map 0:v:0 -map 0:a:0 \
  -c:v copy -af "volume=0:enable='between(t,10,15)'" \
  -c:a aac -b:a 192k output.mp4
```

## Text, Subtitles, Watermarks, Picture-In-Picture

Text overlay:

```bash
ffmpeg -i input.mp4 -filter_complex \
  "[0:v]drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='Hello world':fontcolor=white:fontsize=48:x=(w-text_w)/2:y=h-100:box=1:boxcolor=black@0.5:boxborderw=10[v]" \
  -map "[v]" -map '0:a?' -c:v libx264 -crf 20 -pix_fmt yuv420p -c:a aac output.mp4
```

Show only between 3 and 6 seconds by adding `:enable='between(t,3,6)'`.

Generate subtitles from speech: use the `transcribe_media` tool with `format='srt'` (it follows the transcription provider configured in Settings and writes `input.srt` next to the file). Review the SRT for transcription errors before burning it in.

Burn subtitles into pixels:

```bash
ffmpeg -i input.mp4 -map 0:v:0 -map '0:a?' \
  -vf "subtitles=subs.srt" \
  -c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p \
  -c:a aac -b:a 192k output.mp4
```

Toggleable soft subtitles in MP4:

```bash
ffmpeg -i input.mp4 -i subs.srt -map 0 -map 1 -c copy -c:s mov_text output.mp4
```

Logo watermark:

```bash
ffmpeg -i input.mp4 -i logo.png -filter_complex \
  "[0:v][1:v]overlay=W-w-20:20[v]" \
  -map "[v]" -map '0:a?' \
  -c:v libx264 -crf 20 -pix_fmt yuv420p -c:a aac output.mp4
```

Picture-in-picture:

```bash
ffmpeg -i screen.mp4 -i webcam.mp4 -filter_complex \
  "[1:v]scale=iw*0.25:-2[pip];[0:v][pip]overlay=W-w-20:H-h-20[v]" \
  -map "[v]" -map '0:a?' \
  -c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p -c:a aac output.mp4
```

## Transitions

`xfade` requires matching resolution, frame rate, time base, and pixel format. Normalize first when in doubt. `offset` is usually `first_clip_duration - transition_duration`.

```bash
ffmpeg -i clip1.mp4 -i clip2.mp4 -filter_complex \
  "[0:v]fps=30,format=yuv420p[v0];[1:v]fps=30,format=yuv420p[v1]; \
   [v0][v1]xfade=transition=fade:duration=1:offset=4[v]; \
   [0:a][1:a]acrossfade=d=1[a]" \
  -map "[v]" -map "[a]" \
  -c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p \
  -c:a aac -b:a 192k output.mp4
```

## GIFs

Two-pass palette. Keep GIFs short; for most sharing, MP4 is smaller and better.

```bash
ffmpeg -i input.mp4 -vf "fps=12,scale=480:-2:flags=lanczos,palettegen" -t 10 palette.png
ffmpeg -i input.mp4 -i palette.png -filter_complex "fps=12,scale=480:-2:flags=lanczos[x];[x][1:v]paletteuse" -t 10 output.gif
```

## Common Failures

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Cut starts early/late | Stream-copy trim hit keyframes | Re-encode for frame accuracy |
| Output will not play on phone/web | Pixel format or codec incompatible | Use H.264/AAC and `-pix_fmt yuv420p` |
| Encoder says odd width/height | H.264 needs even dimensions | Use `scale=-2:720` or pad/crop to even dimensions |
| Audio disappears | Wrong `-map` options | Map audio intentionally, often `-map '0:a?'` |
| Audio out of sync after filters | Missing timestamp reset | Use `setpts=PTS-STARTPTS` and `asetpts=PTS-STARTPTS` after trims |
| Slow motion audio fails | `atempo` outside 0.5-2.0 | Chain multiple `atempo` filters |
| Concat fails or desyncs | Inputs do not match | Normalize codec, resolution, fps, pixel format, sample rate, channels |
| Transition fails | Clips differ in geometry/fps/audio | Normalize first; ensure both clips have the needed streams |
| Music overwhelms speech | Music volume too high | Use 0.15-0.35 for music under original audio |
| GIF looks bad | No palette pass | Use palettegen then paletteuse |
| `drawtext` cannot load font | Bad font path | Use a known system font path or omit `fontfile` if supported |
| Reverse runs out of memory | Reverse buffers frames | Split long clips before reversing |
