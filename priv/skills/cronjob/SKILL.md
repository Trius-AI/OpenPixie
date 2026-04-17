---
description: Cron job management
always: false
tags: [cron, scheduling]
---

# Cron Job Management

You can create and manage scheduled tasks (cron jobs) using the following approach:

## Creating a cron job

Use a cron spec to schedule recurring tasks:
- `{daily, Hour}` - Run every day at the specified hour (0-23)
- `{interval, Minutes}` - Run every N minutes
- `{monthly, Day}` - Run monthly on the specified day (1-31)
- `{yearly, Month, Day}` - Run yearly on the specified month (1-12) and day

## Memory condensation

The system automatically runs day condensation at 23:00 daily. You can also trigger manual condensation using the memory tools.