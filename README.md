# Markinim
This is the @MarkinimBot Telegram bot's source code. It's a bit messy (it was never meant to be open source at the beginning) so it needs a cleanup, but it works. Memory usage and performance are pretty good. It uses sqlite.

# Deploy
> For docker instructions, [skip here](#deploy-with-docker)

Install required dependencies:

```shell
$ nimble install
```

Then create a `secret.ini` file which looks like this, where admin is your Telegram user id, and token is the bot token obtainable from @BotFather.

```ini
[config]
token = "1234:abcdefg"
admin = 123456
logging = 1
```

You can also add a `keeplast = 1500` parameter to the configuration, to avoid ram overloads by processing a maximum of keeplast messages per session (default: `1500`)

```shell
$ nim c -o:markinim src/markinim.nim
$ ./markinim
```
## Deploy (with docker)
- Copy `.env.sample` to `.env`
- Edit `BOT_TOKEN` and `ADMIN_ID`
- If needed, edit `KEEP_LAST` (default: `1500`. Read above)
- Build the image with `docker build -t markinim .`
- Run the bot using `docker run -itd -v="${pwd}/data":/code/data:z --env-file=.env --restart=unless-stopped --name=markinimbot markinim`

## Backups
> ⚠️ **WARNING**: This is an experimental backup script. It's not well-tested yet. Use it at your own risk. I am not responsible for any data loss. I don't know if it works.
- Setup [`syncthing`](https://syncthing.net/) if you want to sync the backups to another device
- Edit `tools/backup_script.sh` and set the correct values for `root_dir`, `backup_directory` and `backup_filename`
- Optionally, edit `TELEGRAM_ID` to receive a notification when the backup is done
- Edit `tools/backup_script.service` and set the correct path for `ExecStart`, `WorkingDirectory`, `ExecStartPre` and `ExecStartPost`
- Copy `tools/backup_script.service` to `/etc/systemd/system/`
- ```shell
  $ systemctl daemon-reload
  $ systemctl enable backup_script.service
  $ systemctl start backup_script.service
  ```
