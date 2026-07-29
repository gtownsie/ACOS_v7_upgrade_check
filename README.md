# ACOS v7 Upgrade Check

This repository contains a Bash script that uses the A10 AXAPI to validate whether a Thunder device is ready for an upgrade from ACOS v5/v6 to ACOS v7.

The script connects to the device over HTTPS, authenticates with AXAPI, and checks several system requirements that are commonly required for a successful v7 upgrade.

## What the script checks

The script verifies the following:

- AXAPI authentication succeeds
- Control and data CPU counts meet the minimum requirements
- Current boot image information is available
- License information is present and valid for v7
- Disk size is large enough
- Memory is sufficient
- Shared poll mode is not enabled, since it is not supported in v7

## Prerequisites

Before running the script, make sure the following tools are installed:

- Bash
- curl
- jq

## Usage

Use the following syntax:

ACOS-v7-upgrade-check host <ip address of Thunder> -port <port, leave blank if 443> -username <username> -password <password>

Example:

./v7-upgrade-check.sh -host 192.0.2.10 -username admin -password Secret123

If you prefer to pass values through environment variables, the script also supports:

- HOST
- USERNAME
- PASSWORD
- PORT

## Notes

- If no port is specified, the script uses the default HTTPS port 443.
- The script is intended as a pre-upgrade validation tool and should be run before attempting the ACOS v7 upgrade.
- Review the output carefully. Any failed checks should be addressed before proceeding with the upgrade.
