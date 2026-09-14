# Capturing what Oraimo Health actually sends

This is the most important procedure in the project. Everything we will ever
learn about the Watch 6R protocol starts here.

## Why the app cannot just watch

Android does not let one app observe another app's GATT traffic. There is no
permission for it and no API for it. So the workflow you might expect — start a
capture in this app, switch to Oraimo Health, do something, come back — records
nothing at all.

What *can* see everything is the phone's own Bluetooth stack. Android has a
built-in developer setting that writes every HCI packet, from every app, to a
file. That file is `btsnoop_hci.log`, and this app can import it.

An emulator is not an alternative. It has no Bluetooth radio that can reach a
real peripheral, so the official app cannot talk to your watch inside one.

---

## One-time setup

1. On the phone: **Settings → About phone → tap Build number seven times** to
   enable Developer options.
2. **Settings → System → Developer options → Enable Bluetooth HCI snoop log**
   → turn it on. Some phones offer `Enabled` / `Filtered` — choose the
   unfiltered option, because a filtered log strips the payloads we need.
3. **Toggle Bluetooth off and on.** The setting only takes effect when the
   Bluetooth stack restarts. Skipping this is the single most common reason a
   capture comes back empty.
4. On your computer, confirm the phone is visible:

   ```bash
   adb devices
   ```

---

## Capturing one experiment

Keep each capture to **exactly one operation**. A log containing a sync, a
settings change and a watch-face install is far harder to read than three logs
containing one thing each — the whole point of comparing captures later is that
only one variable changed.

1. **Clear the log.** Turn the snoop log setting off and on again, then toggle
   Bluetooth off and on. This starts a fresh file.
2. **Note the time.** Look at the clock and write it down. Correlating "I tapped
   the button at 21:43:10" against the capture is enormously helpful.
3. **Open Oraimo Health** and let it connect to the watch. Wait for it to
   settle.
4. **Perform exactly one operation** — install a watch face, change the time,
   sync data. Nothing else. Do not browse other screens.
5. **Wait** for it to finish completely. A watch-face transfer may take a while;
   let the progress indicator reach the end.
6. **Close Oraimo Health.**
7. **Pull the log:**

   ```bash
   adb bugreport capture.zip
   unzip -o capture.zip 'FS/data/misc/bluetooth/logs/*'
   ```

   The file you want is
   `FS/data/misc/bluetooth/logs/btsnoop_hci.log`. Some phones also keep
   rotated logs (`btsnoop_hci.log.last`) — keep those too.

   On some devices the log can be pulled directly, which is quicker:

   ```bash
   adb pull /sdcard/btsnoop_hci.log
   ```

8. **Rename it** after the experiment: `watchface-A.btsnoop`,
   `change-time.btsnoop`. You will not remember which was which tomorrow.
9. **Copy it to the phone** (or keep it anywhere the file picker can reach) and
   import it in the app: **Sessions → Import HCI snoop log**.

### What the import shows you

The preview lists every Bluetooth device in the capture, busiest first. Your
phone was probably also talking to headphones, a car or a keyboard; pick the
watch by address. If you are unsure which is which, a watch-face transfer is
overwhelmingly the noisiest thing in the log.

The import also tells you two things it is important not to ignore:

- **Unresolved handles.** If the capture does not contain the moment the phone
  discovered the watch's GATT database, then the app knows which attribute
  handles were written to but not what they are. It reports those handles and
  leaves the UUID empty rather than guessing. To avoid this, make sure
  Bluetooth is toggled *after* snoop logging is enabled, so the fresh
  connection and its service discovery are both inside the capture.
- **Truncated records.** If the capture was configured to store only part of
  each packet, payloads are incomplete and anything concluded from them will be
  wrong. Use the unfiltered snoop log setting.

---

## The watch-face experiment

This is the first real experiment, and the reason the importer exists.

Run the procedure above three times:

| Session name | Operation |
|---|---|
| `connection-test` | Open Oraimo Health, let it connect, change nothing, close it. |
| `watchface-A` | Install one watch face. Note which one. |
| `watchface-B` | Install a different watch face. Note which one. |

The `connection-test` capture is the control: whatever appears in it is
handshake, sync or housekeeping, and is therefore *not* watch-face data. Its
value is in what it lets you rule out.

Then export all three as JSON and compare them. The questions to put to the
evidence, none of which we can answer yet:

- Which characteristic receives the bulk of the data?
- Is the watch face sent as one binary payload, or fragmented?
- If fragmented, what is the fragment size, and does it match the negotiated
  MTU?
- Is there a header before the image data? Does it differ between A and B?
- Does the watch acknowledge each fragment, or only the whole transfer?
- Is there a checksum, and over what?
- Does the payload look compressed or encrypted? Long runs of identical bytes
  suggest neither; uniformly high-entropy data suggests one of them.
- Do A and B share a prefix? Where exactly do they diverge?

Record what you find as **observations** in the Protocol Database, citing the
packets. Record what you think it means as a **hypothesis**, along with what
would disprove it. Resist writing a decoder until a hypothesis has survived a
deliberate attempt to break it.

---

## Troubleshooting

**The imported file is rejected as "not a btsnoop file".**
You almost certainly imported the bugreport zip rather than the log inside it.
Unzip it first.

**The capture contains no BLE connections.**
The watch was already connected when snoop logging started, so the connection
event happened before the log did. Toggle Bluetooth off and on and capture
again.

**The log is empty or tiny.**
The snoop log setting did not take effect. Toggle Bluetooth off and on after
enabling it.

**Every handle is unresolved.**
Service discovery happened outside the capture window. Same fix: toggle
Bluetooth so the connection is re-established inside the capture.

**The watch does not appear when scanning in this app.**
A connected BLE peripheral generally stops advertising. Disconnect it in Oraimo
Health first, or force-stop that app.
