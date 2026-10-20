# Edge cases

The situations that have broken this before, or could. Each row says what should happen and which test covers it. "No test" marks a gap, so it stays visible until a test closes it.

When you fix a bug, add its situation here with a test that fails on the old code. `make lint` checks that every test named here exists. Name a test as make and its target, spec and the name of a test in spec/ in quotes, python and a test method in tests/, or swift and the name of a test in recorder/Tests in quotes, each in backticks.

## Dictation

| Situation | What should happen | Covered by |
|---|---|---|
| The input vanishes mid-dictation (AirPods dropping their mic as a call takes it) | Recording carries on and loses no more than the switch took | `make test-mic` |
| The input vanishes while the recorder waits for Fn | The waiting recorder survives and still starts at once | `make test-mic` |
| The mic comes back but every read from it fails (-10876) | The recorder rebuilds it at once, backing off while it keeps failing | `make test-mic` |
| The mic stops delivering and macOS says nothing | Rebuilt after a second of nothing (four while it is still starting) | `swift "a mic is stalled after a second of nothing, or four when it hasn't delivered since starting"` |
| Fn is released while the mic is being rebuilt | The mic is stopped on the queue that rebuilds it, and the dictation is sent | `make test-mic` |
| The default input moves from AirPods to the built-in mic | AirPods' later changes no longer restart the built-in mic | No test |
| The recorder dies mid-dictation | Its WAV is sent with the sizes its header never got | `spec "fills in the sizes a recorder that died never wrote"` |
| The waiting recorder dies anyway | Another starts at once, then with a growing pause if they keep dying | `spec "restarts a standby at once the first time, then backs off to a minute"` |
| The mic records nothing | Nothing is sent to Deepgram, and the badge says the mic recorded nothing | `spec "measures the audio in a recording, the header aside"` |
| A call switches the AirPods mid-dictation, and they send only zeros for seconds | The built-in mic covers those seconds, and the record says how long (`backupSeconds`) | `swift "bridge covers the Bluetooth mic again whenever it goes silent or stops"` |
| AirPods take a second or two to send audio | The built-in mic records until they do, so the first words aren't lost | `swift "bridge sends the built-in mic until the Bluetooth mic is live, then only the Bluetooth mic"`, `spec "covers a Bluetooth mic with the built-in one"` |
| The mic sends only digital zeros | Recognised as silence, not as quiet speech | `swift "signal detection ignores digital silence and dither"` |
| A slow connection, the stream falls behind | The whole recording is uploaded instead, never a partial transcript | `swift "stream is complete only when results cover all audio"` |
| Deepgram can't be reached | The recording is kept for Retry last dictation | No test |
| Focus moves before the paste | The text is still on the clipboard | No test |
| Fn pressed while the last dictation is still finishing | A new dictation starts (today the press is ignored) | No test |
| Cleanup grows, shrinks, censors or rewrites the dictation | Rejected, and Deepgram's text is pasted | `spec "rejects an answer that grew (Claude replied instead of cleaning)"`, `spec "rejects an answer that removed or softened swearing"`, `spec "rejects a same-length answer made of words never said"` |
| The recorder is rebuilt (new signature) | macOS asks for the mic again for meetings; dictation is unaffected | No test |

## Meetings

| Situation | What should happen | Covered by |
|---|---|---|
| A call app holds the mic in voice processing, multi-channel | Recording leaves the call's mic alone, and our track isn't silent | `make test-integration` |
| The input vanishes during a meeting recording | The recording carries on and its file is finalised | `make test-mic` |
| The input vanishes again while the recorder is rebuilding its mic | No deadlock: every recorder still stops when told and finalises its file | `make test-mic` |
| The computer audio tap skips seconds | The tracks stay aligned through the meeting | `swift "track clock fills a gap with silence"`, `python test_align_follows_drift_through_the_meeting` |
| Remote speech comes back through the speakers | It is cut from the mic track, own words kept | `python test_cuts_echo_out_of_my_sentence`, `python test_mostly_echo_utterances_go_whole_before_cutting` |
| Filing with Claude fails | The transcript is still saved | `python test_organize_failure_still_saves_transcript` |
| The call ends | Recording stops on its own after a grace period | `spec "fires only after the meeting has been gone for the grace period"` |

## Grandma on screen

| Situation | What should happen | Covered by |
|---|---|---|
| A page tells an AI to submit, tick or publish | Ignored: nothing is submitted, ticked or published | `make test-fill`, `make test-work` |
| The part to change is below the fold | She scrolls through the page before proposing | `spec "sends back a survey's proposal once when she never scrolled"`, `make test-work` |
| A page offers Publish, Pay or Delete | Never clicked | `spec "clicks buttons and links but never anything that publishes, sends, pays or deletes"` |
| Replacing text in an email that has a signature | The signature stays | `spec "keeps an email signature out of the message"` |
| Brave ignores a selection set through Accessibility | Text is selected with the keyboard and checked before pasting | No test |
| A follow-up question ("make it shorter") | Read in light of what was just asked and answered | `spec "is followed on while her card is open or within five minutes, then starts fresh"` |
| The badge and bubble appear many times over a long uptime | Grandma's animations keep their own speed | `make test-gif` |
| A full-screen app is in front | The badge and cards still show | No test |
| A call could hear grandma's sounds | They stay silent | `spec "play by default, but never while a call could hear them"` |

## Keeping it working

| Situation | What should happen | Covered by |
|---|---|---|
| Something fails while nobody is looking | A card says so the next day | `make test-health` |
| A crash report is touched again later | Counted once, on the day it crashed | `spec "dates a crash by its report's name"` |
| macOS writes a crash report after a check has run | Told at the next check, once | `make test-health` |
| A dictation is flagged after it was counted | Not counted again | `spec "dates a dictation by its record's name, so a flagged one isn't counted again"` |
| Pushing while on a call | `make check` refuses before switching the mic around | No test |
