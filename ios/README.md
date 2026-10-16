# Passport Agent (iOS/iPadOS 27+)

See [简体中文](README.zh_CN.md). This native app runs the screen-to-model-to-Passport loop without a computer.
It requires explicit full-display sharing consent and an AI Passport firmware build from this repository.

Generate the Xcode project with `xcodegen generate`, select your development team, and run on a physical device.
The API key is stored in Keychain. Screen JPEGs, the task, and recent actions are sent to the configured HTTPS model endpoint.
