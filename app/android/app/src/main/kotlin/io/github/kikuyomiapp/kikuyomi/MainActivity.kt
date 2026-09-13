package io.github.kikuyomiapp.kikuyomi

import com.ryanheise.audioservice.AudioServiceActivity

// audio_service's activity shares one Flutter engine with its background playback service, so the
// book keeps playing, and its controls keep working, after the activity is gone.
class MainActivity : AudioServiceActivity()
