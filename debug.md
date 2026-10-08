# Debug & Fix LocalTalk App — Host/Guest Local Network Connection

You are working on an existing **LocalTalk** app. Your task is to **debug the current implementation, identify the root causes, and fix the connectivity flow**.

Do NOT rewrite the entire application from scratch. First inspect the existing code, architecture, networking logic, permissions, and UI flow. Preserve the existing functionality and design wherever possible.

## Current Problems

### 1. Host Room Creation / Hotspot

When the host creates a room:

* The app currently does **not automatically enable/start the required hotspot or local network connection**.
* The host receives an IP address similar to:

```text
10.123.xx.xx
```

However, this does not appear to match the network configuration expected by the guest.

Investigate:

* How the host's local IP is detected.
* Which network interface/IP is being used.
* Whether the app is expecting Wi-Fi, mobile hotspot, Wi-Fi Direct, or another local networking mechanism.
* Whether Android/iOS/OS restrictions prevent the app from programmatically enabling a hotspot.
* Whether the backend/server is actually binding to the correct network interface.
* Whether the displayed IP is reachable from another device.

Do not assume the IP format is the problem. **Trace the actual network configuration and determine why host and guest cannot communicate.**

---

## 2. Guest IP Input Problem

The guest currently has an IP input field that expects something resembling:

```text
192.10.XXXXXXXXX
```

while the host may provide something like:

```text
10.123.xx.xx
```

These formats/configurations don't match.

Fix the guest connection flow so that:

* The guest accepts a valid IPv4 address.
* IP validation follows proper IPv4 rules.
* The app does NOT hardcode a `192.x.x.x` network.
* The guest connects to the actual address/endpoint exposed by the host.
* The port is handled automatically where possible.
* The user should not need to understand networking concepts.

Example:

```text
Host:
IP: 10.123.45.67
Port: 8080

Guest:
Connect → automatically uses the host's advertised address
```

Do not simply change the validation regex. Find and fix the underlying networking mismatch.

---

## 3. Microphone Permission

The app currently shows a microphone-related error, but **does not properly request microphone permission**.

Fix the complete permission flow.

Requirements:

1. Detect whether microphone permission has already been granted.
2. If not granted, request it using the platform's proper permission API.
3. Show a clear explanation before requesting permission if appropriate.
4. Handle:

   * Permission granted
   * Permission denied
   * Permission permanently denied
   * Microphone unavailable
   * Another application currently using the microphone
5. Only initialize microphone/audio functionality after permission has been successfully granted.
6. Replace vague errors such as:

```text
Microphone error
```

with useful messages explaining what the user needs to do.

Also verify that the required microphone permission is correctly declared in the project's platform configuration.

---

# 4. Make Host → Guest Connection Automatic

The biggest goal is to make LocalTalk feel like a **simple local communication app**, not a networking configuration tool.

The user should not have to manually figure out:

* IP addresses
* Network ranges
* Ports
* Server addresses
* Hotspot settings
* Microphone permissions
* Connection configuration

Design the flow around this:

### HOST FLOW

```text
Open LocalTalk
        ↓
Create Room
        ↓
Check network availability
        ↓
Prepare local network / hotspot
        ↓
Start LocalTalk server
        ↓
Detect correct local IP
        ↓
Generate Room ID / QR
        ↓
Show:
"Waiting for guests..."
        ↓
Guest connects
        ↓
Connected
```

### GUEST FLOW

```text
Open LocalTalk
        ↓
Join Room
        ↓
Scan QR
        ↓
App extracts connection information
        ↓
Connect automatically
        ↓
Verify connection
        ↓
Connected
```

The guest should preferably **never manually type an IP address**.

Keep manual IP entry only as an advanced/fallback option.

---

# 5. QR Code Connection

After the host successfully creates a room, provide a QR-code option.

The QR code should contain the minimum information required for the guest to connect, for example:

```json
{
  "ip": "10.123.45.67",
  "port": 8080,
  "roomId": "ABC123",
  "protocol": "http"
}
```

Use the actual protocol and connection architecture already used by the application.

### Host UI

After room creation:

```text
Room Created

Room ID: ABC123

Waiting for guests...

[ QR CODE ]

Scan this QR code to join

or

[ Show Connection Details ]
```

### Guest UI

```text
Join Room

[ Scan QR Code ]

──────── OR ────────

Enter Room Code

[____________]

[ Connect ]
```

If QR scanning succeeds:

```text
Connecting to room...
        ↓
Connection verified
        ↓
Connected ✓
```

If it fails:

```text
Unable to connect.

Make sure:
• You are connected to the host's network
• The host's LocalTalk room is still active
• Both devices are nearby

[ Try Again ]
[ Enter IP Manually ]
```

---

# 6. Important: Understand Platform Restrictions

Before implementing automatic hotspot functionality, inspect the target platform.

If the platform **does not allow third-party applications to silently enable/configure a hotspot**, do not create a fake implementation.

Instead:

1. Detect whether the required network is available.
2. If hotspot activation cannot be performed programmatically:

   * Show a clear system-guidance screen.
   * Tell the host exactly what to do.
   * Provide a button that opens the appropriate network/hotspot settings when the platform allows it.
3. Once the host enables the network, automatically detect the network and continue the setup.

The experience should still feel automatic even when the operating system requires user interaction.

Example:

```text
Local network required

LocalTalk needs a local network for nearby communication.

[ Open Hotspot Settings ]

After enabling the hotspot,
return to LocalTalk.

Waiting for network...
```

Do not claim that the app can control system settings if the platform doesn't permit it.

---

# 7. Network Discovery

Investigate whether the app can avoid IP addresses completely.

Depending on the platform and existing architecture, consider:

* mDNS / Bonjour
* UDP discovery
* NSD
* Wi-Fi Direct
* Nearby Connections
* Local network service discovery
* Existing backend/server discovery mechanism

The best solution should be based on the **actual platform and framework used by this project**.

Do not add unnecessary technologies just for the sake of it.

The QR code should remain a reliable fallback even if automatic discovery is unavailable.

---

# 8. Debugging Requirements

Before making changes:

### Inspect

* Project structure
* Framework and platform
* Current networking implementation
* Host server implementation
* Guest connection implementation
* IP detection logic
* Port configuration
* Socket/WebSocket implementation
* HTTP implementation
* Permission handling
* Android/iOS configuration
* QR implementation if one already exists

### Then identify

For every issue, determine:

```text
Problem
↓
Root cause
↓
Fix
↓
How the fix was verified
```

Do not patch symptoms without understanding the root cause.

---

# 9. Error Handling

Add useful user-facing states:

```text
Preparing room...
Checking network...
Starting local server...
Finding network address...
Room ready
Waiting for guests...
Connecting...
Connected
Connection lost
Retrying...
Microphone permission required
Microphone unavailable
Network unavailable
Host unreachable
Invalid QR code
Room expired
```

Avoid exposing raw exceptions to users.

For debugging, keep useful logs in development mode.

---

# 10. Testing

After implementing the fixes, test the complete flow using **two physical devices** if the project supports them.

### Test A — Host

* Launch app
* Create room
* Verify network setup
* Verify correct IP detection
* Verify server starts
* Verify QR code generation
* Verify microphone permission

### Test B — Guest

* Launch app
* Scan host QR
* Verify QR data
* Verify IP/port extraction
* Connect to host
* Verify communication
* Verify microphone/audio functionality

### Negative tests

Test:

* Host has no network
* Guest is on a different network
* Invalid IP
* Invalid QR
* Host closes room
* Host disconnects
* Guest disconnects
* Microphone permission denied
* Microphone permission permanently denied
* Server fails to start
* Port unavailable
* Network changes while connected

---

# 11. Important Constraints

Follow these rules:

* **Do not rewrite the project unnecessarily.**
* Reuse existing architecture where possible.
* Do not hardcode `192.168.x.x` or any specific IP range.
* Do not hardcode a fake IP.
* Do not assume `10.x.x.x` is incorrect; private IPv4 ranges are valid.
* Do not ask users to manually configure networking unless the operating system requires it.
* Do not silently fail.
* Do not hide connection errors.
* Do not request microphone access only after the microphone has already failed.
* Do not expose raw technical errors to normal users.
* Keep manual IP connection as a fallback, not the primary flow.
* Prefer QR-based connection for the initial implementation.
* Keep security in mind: do not allow arbitrary devices to connect without appropriate room/session validation.

---

# 12. Final Deliverable

After debugging, provide:

### 1. Root Cause Report

For each existing problem:

```text
Issue:
Root cause:
File(s) affected:
Fix:
```

### 2. Code Changes

Implement the fixes directly in the existing project.

### 3. User Flow

Ensure the final experience is:

```text
HOST

Create Room
    ↓
Network ready
    ↓
Local server started
    ↓
QR generated
    ↓
Waiting for guest


GUEST

Scan QR
    ↓
Connection information extracted
    ↓
Connect automatically
    ↓
Room/session verified
    ↓
Connected
```

### 4. Verification

Run the available tests/build/lint commands and report:

* What passed
* What failed
* What could not be tested
* Any platform limitations

If physical-device testing is required but unavailable, clearly state that instead of claiming it was tested.

**Start by inspecting the existing project and tracing the host → network → IP → QR → guest → connection → microphone flow before modifying anything.**
