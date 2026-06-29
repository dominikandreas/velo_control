# Velo Control

Velo Control is a cross-platform application used to interface with and control a Velo Speeder over Bluetooth Low Energy (BLE). It features a modern user interface and natively supports Windows, Android, iOS, and the Web.

This repository contains two components:
1. **Flutter Application**: A cross-platform mobile/desktop app for controlling the speeder switch via BLE.
2. **Vite Companion Web App**: A Node-based web dashboard.

## Prerequisites

### For the Flutter App
- [Flutter SDK](https://flutter.dev/docs/get-started/install)
- **For Android:** Android Studio & Android SDK
- **For Windows:** Visual Studio 2022 with the "Desktop development with C++" workload
- **For iOS:** macOS, Xcode, and CocoaPods

### For the Vite Companion App
- [Node.js](https://nodejs.org/en/) (v16+)

---

## 🚀 Running the Flutter Application

The Flutter application relies on `flutter_blue_plus` to communicate over BLE. 

### 1. Install Dependencies
```bash
flutter pub get
```

### 2. Run the App

**On Windows:**
```bash
flutter run -d windows
```

**On Android:**
Ensure an Android device or emulator is connected, then run:
```bash
flutter run -d <your-device-id>
```
*(Note: Android 12+ dynamically requests the correct Bluetooth scanning permissions without requiring Location access).*

**On iOS (Requires a Mac):**
Install iOS pod dependencies first:
```bash
cd ios
pod install
cd ..
flutter run -d ios
```

**On Web:**
```bash
flutter run -d chrome
```

---

## 🌐 Running the Vite Companion Web App

The project also includes a Vite app for web-based AI Studio integrations.

### 1. Install Dependencies
```bash
npm install
```

### 2. Environment Variables
Copy `.env.example` to `.env.local` and add any necessary configurations (e.g. `GEMINI_API_KEY`).
```bash
cp .env.example .env.local
```

### 3. Start the Development Server
```bash
npm run dev
```

---

## Contributing
- **Code Style:** Follow the standard Dart guidelines. Use `flutter format .`
- **Git Hooks:** Before committing, ensure the project builds correctly across platforms.
