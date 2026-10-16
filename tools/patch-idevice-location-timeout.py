from pathlib import Path
import sys


source = Path(sys.argv[1])
text = source.read_text(encoding="utf-8")

old_import = "use plist::Value;\n"
new_import = "use plist::Value;\nuse std::time::Duration;\n"
if text.count(old_import) != 1:
    raise SystemExit("Unexpected idevice source: could not locate unique plist import")
text = text.replace(old_import, new_import, 1)

old_clear = '''        self.channel.call_method(Some(method), None, true).await?;

        let _ = self.channel.read_message().await?;'''
new_clear = '''        // DVT replies are not guaranteed to arrive after a tunnel interruption.
        // Bound the whole request so a stale RemoteXPC channel cannot pin the
        // caller forever; the FFI caller can then discard and rebuild it.
        crate::time::timeout(Duration::from_secs(5), async {
            self.channel.call_method(Some(method), None, true).await?;
            let _ = self.channel.read_message().await?;
            Ok::<(), IdeviceError>(())
        })
        .await
        .map_err(|_| IdeviceError::Timeout)??;'''
old_set = '''        self.channel
            .call_method(
                Some(method),
                Some(vec![
                    AuxValue::archived_value(latitude),
                    AuxValue::archived_value(longitude),
                ]),
                true,
            )
            .await?;

        // We don't actually care what's in the response, but we need to request one and read it
        let _ = self.channel.read_message().await?;'''
new_set = '''        // A dropped DVT response must fail promptly so the app can rebuild
        // the tunnel instead of blocking every future location resend.
        crate::time::timeout(Duration::from_secs(5), async {
            self.channel
                .call_method(
                    Some(method),
                    Some(vec![
                        AuxValue::archived_value(latitude),
                        AuxValue::archived_value(longitude),
                    ]),
                    true,
                )
                .await?;

            // We don't care about the response contents; its arrival confirms
            // that the remote service handled the location request.
            let _ = self.channel.read_message().await?;
            Ok::<(), IdeviceError>(())
        })
        .await
        .map_err(|_| IdeviceError::Timeout)??;'''

for old, new, label in ((old_clear, new_clear, "clear request"), (old_set, new_set, "set request")):
    if text.count(old) != 1:
        raise SystemExit(f"Unexpected idevice source: could not locate unique {label}")
    text = text.replace(old, new, 1)

source.write_text(text, encoding="utf-8")

