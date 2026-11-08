# Blueprint

A personal native iPhone app that reads a wearable's standard Bluetooth heart rate signal, for use when the original service is no longer active.

Not affiliated with any wearable maker. Not a medical device. All scores are estimates.

## Rules that do not change

1. **Personal data never goes in this repo.** No exports, baselines, heart rate zones, names or keys. This repo is code only, and it is public.
2. **Keep raw readings.** Scores are calculated from stored heart rate and R-R data, so a better formula can be applied to old nights.
3. **Every record belongs to a profile,** so two people's bands never mix.
4. **Listen only.** The app does not write commands to the band. The optional alarm is the only planned exception, and it comes last.
5. **Use the standard Bluetooth Heart Rate service,** so a chest strap or armband can replace the band without losing the app or its history.
6. **Backup and restore come early,** because deleting the app erases its data.
7. **The app may not contact any server,** except the single AI function in Step 5. No analytics, ads or third-party libraries.

## Why native

A web page in a Bluetooth browser stopped recording when the phone locked. iPhone apps can declare background Bluetooth, which keeps a connection running with the screen off.

## Building and installing

- No Mac is needed. GitHub Actions compiles the app on a cloud Mac and publishes an unsigned install file.
- The file is signed and installed from a Windows computer with a free Apple account, and must be re-signed every 7 days.
- AI step only: one small server function outside this repo holds the API key and accepts requests only from this app.

## Build order

| Step | What ships | Depends on |
|---|---|---|
| 1. Locked-screen proof | Raw logging, gaps, battery, report, background recording | Nothing |
| 2. Live and workouts | Live view, start and stop, zones, averages, suggested activities | Step 1 storage |
| 3. Sleep and trends | Sleep detection, estimated sleep score, HRV, resting heart rate, recovery trend, strain, history import, backup | Step 1 result |
| 4. Meals | Search, free text, favorites, calories and macros, avoid-list flags, steps from Apple Health | Step 3 screens |
| 5. AI | Natural-language meal entry, photo estimates, questions about trends | Server function |
| 6. Alarm (optional) | Set the band's alarm from the app, dropped if too complicated | Community protocol work |

## Data model

- Session files: one samples file (time, heart rate, format flags, R-R intervals) and one events file (start, connected, disconnected, background, locked, battery)

Later steps add `workouts`, `sleeps`, `daily`, `meals` and `foods`, all keyed by profile.

## Sleep score (Step 3)

Personal weights are fitted on the phone from the user's own imported history, using hours vs. needed, consistency and efficiency. Sleep stages are not shown, because heart rate alone cannot support them.

## Known limits

- Recording needs the phone nearby. Force-quitting the app stops it.
- The band's stored history, motion, skin temperature and SpO2 are not readable on this model yet.
- The live heart rate signal is unencrypted and can be read by devices nearby.
