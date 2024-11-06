# Servarr Installation Script

This script is inspired by the community Servarr installation script. It automates the installation process of various *arr applications (Lidarr, Prowlarr, Radarr, Readarr, Sonarr, and Whisparr) on Debian-based Linux distributions.

## Author

Christian Blank (cyneric)
GitHub: https://github.com/cyneric

## Features

- Easy interactive installation process
- Supports multiple Servarr applications:
  - Lidarr (Music)
  - Prowlarr (Indexer)
  - Radarr (Movies)
  - Readarr (Books)
  - Sonarr (TV Shows)
  - Whisparr (Adult Movies)
- Automatic dependency installation
- Systemd service configuration
- User/group management
- Proper file permissions setup
- Support for multiple architectures (amd64, armhf, arm64)

## Prerequisites

- Debian-based Linux distribution:
  - Debian 10 (Buster) or later
  - Ubuntu 20.04 LTS or later
  - Linux Mint 20 or later
  - Pop!_OS 20.04 or later
  - Elementary OS 6.0 or later
  - Any other modern Debian derivative
- Root access or sudo privileges
- Basic understanding of Linux file permissions

## Installation

#### Option 1
##### Download and run the script in one step using CURL:
```bash
curl -s https://raw.githubusercontent.com/Cyneric/servarr-install-script/main/servarr-install-script.sh | sudo bash
```

#### Option 2
##### Do it manually:
1. Download the script:
```bash
wget https://raw.githubusercontent.com/Cyneric/servarr-install-script/main/servarr-install-script.sh
```

1. Make it executable:
```bash
chmod +x servarr-install-script.sh
```

1. Run the script as root:
```bash
sudo ./servarr-install-script.sh
```

1. Follow the interactive prompts to:
   - Select which application to install
   - Choose the user/group to run the service
   - Confirm installation settings

## Default Installation Paths

- Binary files: `/opt/<AppName>`
- Application data: `/var/lib/<appname>/`
- Service file: `/etc/systemd/system/<appname>.service`

## Post-Installation

After installation, the application will be:
- Running as a systemd service
- Accessible via web interface at `http://<your-ip>:<port>`
- Configured to start automatically on system boot

Default ports:
- Lidarr: 8686
- Prowlarr: 9696
- Radarr: 7878
- Readarr: 8787
- Sonarr: 8989
- Whisparr: 6969

## Troubleshooting

If the service fails to start:

1. Check the service status:
```bash
sudo systemctl status <appname>
```

2. View the logs:
```bash
sudo journalctl -u <appname> -f
```


## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Credits

Special thanks to:
- DoctorArr (doctorarr@the-rowlands.co.uk)
- Bakerboy448
- And other members of the Servarr community

## License

This project is licensed under the MIT License.
