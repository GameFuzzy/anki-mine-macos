#!/usr/bin/env bash

# MIT License

# Copyright (c) 2024 GameFuzzy

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# ---------------------- README ----------------------

# Consult 'anki-mine --help' for instructions on how to use the script.

# DEPENDENCIES: - python 3.9 or higher, sox, ffmpeg, jp-mining-note (you only
# need to have the add-on installed; you do not have to use it as your note
# type).

# - For recording audio you'll need an audio loopback driver such as
# https://github.com/ExistentialAudio/BlackHole. Instructions on how to set up
# BlackHole can be found here:
# https://github.com/ExistentialAudio/BlackHole/wiki/Multi-Output-Device.

# You can either configure it to be used as your system-wide default audio
# output as is shown in the last step of the linked guide (not recommended) or
# configure it to only be the default output for Wine by using 'winecfg' and,
# under the Audio submenu, choosing "Multi-Output device" as the default audio
# output device.

# Contact me on Discord @gamefuzzy if you need any help with setting it up.

# NOTES: The script will not work if you change the filename from "anki-mine.sh"
# to something else.
#
# You may need to change some of the configuration options below:

# ------------------ END OF README -------------------

# ---------------------- CONFIG ----------------------

# Anki:
anki_path="$HOME/Library/Application Support/Anki2" # Path to your Anki installation
anki_user="User 1" # The name of your Anki profile
input_device="BlackHole 2ch" # The name of the audio input device that the script will record audio from

# Note type (defaults are for jp-mining-note):
image_field="Picture" # The name of your note type's image field
audio_field="SentenceAudio" # The name of your note type's sentence audio field

# Preferences:
manual_window_selection=false # Set this to true if you want to be able to manually select which window to capture
hotkey_script_path="$anki_path/addons21/301910299/tools/hotkey.py" # If you're not using jp-mining-note and don't want to install the entire add-on just for this then you can grab this file: https://raw.githubusercontent.com/arbyste/jp-mining-note/dev/tools/hotkey.py and point this variable at it.

# Media format:

# Audio
opus=false # Will not work on iOS devices or older Android devices

# Images
avif=true # Will produce smaller files but will not work on older devices, e.g. iOS <16
avif_compression=32 # Valid range is 0 to 63, higher numbers indicating LOWER quality and SMALLER output size
webp_quality=75 # Valid range is 0 to 100, higher numbers indicating HIGHER quality and LARGER output size

# ------------------ END OF CONFIG -------------------

output_path="$anki_path/$anki_user/collection.media/mining_media-$(date +%s%N)"

my_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp/}$(basename "$0").XXXXXXXXXXXX")
trap "rm -rf $my_tmp_dir" EXIT


display_usage_and_exit () {
        echo "Usage: $(basename "$0") [-s | -b | -a | -m FUNCTION | --help]
        Arguments:
        -s, --screenshot                        Take screenshot and add it to your last added Anki card.
        -b, --screenshot_blur                   Take screenshot and add it to your last added Anki card with the nsfw tag.
        -a, --audio                             Record audio and send it to your last added Anki card.
        -m FUNCTION, --miscellaneous FUNCTION   Run function in jpmn hotkey script (see: https://arbyste.github.io/jp-mining-note-prerelease/scripts/#other-hotkeys).
        -h, --help                              Show this help message and exit." 

        exit 1
}

if [ $# -eq 0 ] ; then
        echo "No arguments supplied."
        display_usage_and_exit
fi

# Transform long options to short ones
for arg in "$@"; do
        shift
        case "$arg" in
                '--screenshot')       set -- "$@" '-s'   ;;
                '--screenshot_blur')  set -- "$@" '-b'   ;;
                '--audio')            set -- "$@" '-a'   ;;
                '--miscellaneous')    set -- "$@" '-m'   ;;
                '--help')             set -- "$@" '-h'   ;;
                *)                    set -- "$@" "$arg" ;;
        esac
done

capture_screenshot () {
        output="$output_path.webp"
        tmp_file="$my_tmp_dir/screenshot"

        echo "Taking screenshot..."

        if $manual_window_selection ; then
                # Interactive window capture
                screencapture -S -W -t jpg "$tmp_file"
        else
                screencapture -R $(osascript -e 'tell application "System Events" to get {position, size} of first window of (first process whose frontmost is true)' | tr -d ' ') -t jpg "$tmp_file"

        fi

        osascript -e 'display notification "Captured screenshot" with title "Mining"'
        echo "Compressing image..."
        if $avif ; then
                output="$output_path.avif"
                ffmpeg -i "$tmp_file" -f avif -c:v libaom-av1 -crf $avif_compression "$output"
        else
                output="$output_path.webp"
                ffmpeg -i "$tmp_file" -f webp -c:v libwebp -compression_level 6 -quality $webp_quality "$output"
        fi

        input=$output
}

capture_audio () {

        if ! command -v sox &> /dev/null ; then
                echo "SoX could not be found."
                exit 1
        fi

        if ! command -v ffmpeg &> /dev/null ; then
                echo "ffmpeg could not be found."
                exit 1
        fi


        sox_info=($(ps -eo ppid,pid,comm | sed -n 's/[^[:space:]]*sox$//p' | xargs)) # "ppid pid"

                parent_process=$(ps -o command= -p "${sox_info[0]}")
                if [[ $parent_process =~ "anki-mine.sh -a" || $parent_process =~ "anki-mine.sh --audio" ]]; then
                        kill -15 "${sox_info[1]}"
                        echo "Stopping recording..."
                        osascript -e 'display notification "Stopped recording audio" with title "Mining"'
                        exit 0
                fi

                output="$output_path"
                tmp_file="$my_tmp_dir/audio.wav"

                echo "Recording audio..."
                osascript -e 'display notification "Started recording audio" with title "Mining"'
                sox -t coreaudio "$input_device" "$tmp_file" silence 1 0 -50d
                if $opus ; then
                        output="$output_path.opus"
                        # Mono VBR Opus with a target bitrate of 24kBit/s
                        ffmpeg -i "$tmp_file" -f opus -b:a 24k -ac 1 -c:a libopus -application voip -apply_phase_inv 0 -af "loudnorm=I=-16:TP=-6.2:LRA=11:dual_mono=true" "$output"
                else
                        output="$output_path.mp3"
                        # Mono MP3 V3
                        ffmpeg -i "$tmp_file" -f mp3 -q:a 3 -ac 1 -af "loudnorm=I=-16:TP=-6.2:LRA=11:dual_mono=true" "$output"
                fi

                input=$output
        }

        hotkey_script () {
                python "$hotkey_script_path" "$@"
        }

# Get options
while getopts ':sbam:' OPTION; do
        case "$OPTION" in
                s)
                        capture_screenshot
                        hotkey_script set_picture "$input" --field-name "$image_field"

                        ;;
                b)
                        capture_screenshot
                        hotkey_script set_picture "$input" --nsfw True --field-name "$image_field"

                        ;;
                a)
                        capture_audio
                        hotkey_script set_audio "$input" --field-name "$audio_field"

                        ;;
                m)
                        script="$OPTARG" 
                        hotkey_script "$script"

                        ;;
                ?)
                        display_usage_and_exit
                        ;;

                esac
        done

