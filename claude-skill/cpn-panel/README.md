# Computing Power Network - Claude panel

A panel beside the Claude chat (Claude Code desktop app or terminal) for the
[Computing Power Network](https://github.com/RoboBadgersRomania/OfflLoadProcessingPowerLink):
every nuclear powerplant on your Tailscale network with a live dot (green ready, yellow owner
using it / job paused, blue not shared, red offline), its specs (GPU, CPU, RAM) and load, and
quick actions on the selected one: Status, Processes, Start, Sleep (with "anyway" when busy),
Sleep after finish, Wake (through the wake listener, from any network), Resume job, Refresh.
Reopen it any time with `/cpn`.

Needs: Windows, Tailscale signed in, and the Computing Power Network installed on this PC
(`SETUP-my-PC.cmd` or `SETUP-everything.cmd`). It uses Windows' own `ssh.exe` and your Ubuntu
username (read from this PC's Ubuntu the first time).

## Install

In a Claude Code terminal session:

```
/plugin install computing-power-network --marketplace RoboBadgersRomania/OfflLoadProcessingPowerLink
```

Answer `y` to add the marketplace, then pick a scope. In the desktop app: click + next to the
prompt box, Plugins, Add marketplace `RoboBadgersRomania/OfflLoadProcessingPowerLink`, then add
the plugin.
