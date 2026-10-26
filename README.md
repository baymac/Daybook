# Daybook

A private Mac dashboard for app and website time, productivity categories, app switches, and your daily timeline. Background video counts too.

![Daybook dashboard with fictional activity](docs/images/dashboard.jpg)

[Apps & sites screenshot](docs/images/apps-and-sites.jpg)

Your activity stays on your Mac. No telemetry, cloud account, or activity uploads. Screenshots use fictional data.

## Set up

Requires Apple silicon, macOS 14+, and Xcode command line tools.

```sh
./build.sh
open .build/Daybook.app
```

Click **Start tracking**, then use **Settings**:

- **Website domains:** enable and approve browser Automation access.
- **Video playback:** open **Setup guide** to install and pair the Brave/Chrome/Edge extension. It needs website access for embedded players; signals stay local.
- **Open at login:** move the app to Applications first. Correct categories in **Apps & sites**.

Video and work can overlap; computer usage counts that time once. Builds are locally signed, not notarized.

## Contribute

Ask Codex to fix an issue on your Mac or add a feature, then send a pull request. Fixes, features, and pull requests are welcome. Run `./test.sh` before submitting (Swift, Node.js, Python 3).

[MIT license](LICENSE).

Built with Codex and [REA](https://github.com/morluto/rea), using [Timecard](https://www.timecardmac.site/) as a reference.
