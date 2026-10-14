# Rollout plan: from "not trusted" to "most trusted tool"

How I would use the scorecard to rebuild trust in a monitoring platform across a large office fleet.
Each phase has a measurable exit, so progress is visible instead of anecdotal.

| Phase | Weeks | Work | Exit measure |
|---|---|---|---|
| 1. Baseline | 1 to 4 | Export 30 days of alerts and tickets, map the columns, run the scorecard, share the first report | Trust score, alerts per office per week, and MTTD/MTTR recorded as the starting line |
| 2. Cut the noise | 5 to 12 | Retire or rewrite every "Retire" rule; give every rule a named owner and a one-line runbook | Zero ownerless rules; alert volume down by the share the projection predicted |
| 3. Correlate | 13 to 24 | Model site dependencies (WAN, firewall, server) so a site outage pages once, with symptoms attached | Pages per site outage close to 1 |
| 4. Tune and harden | 25 to 52 | Work the "Tune" list: thresholds, durations, flap suppression; alert on what an office feels | Trust score above an agreed target, reviewed monthly |
| 5. Sustain | Ongoing | Run the scorecard on a schedule; any new rule must earn "Keep" within 60 days or it goes | Trust holds or rises quarter over quarter |

**Principle:** every alert needs an owner, a runbook, and an action. If an alert fired ten times and nobody acted, it is not monitoring, it is noise.
