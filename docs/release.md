# リリース手順(署名)

ストアに提出するアプリは、開発者の鍵で署名する必要があります。鍵とパスワードは秘密情報のため、リポジトリには含めません。

> **重要: 鍵ファイルとパスワードは絶対に失くさないでください。**
> Android では、一度公開したアプリの更新は同じ鍵で署名しないとインストールできません(Google Play では、Play App Signing を使っていれば「アップロード鍵」のリセットを申請できますが、手続きに時間がかかります)。
> 鍵ファイルはパスワードマネージャーや暗号化した外部ストレージなど、リポジトリ以外の安全な場所に必ずバックアップしてください。

## Android

### 1. 鍵(キーストア)を作る

JDK 付属の `keytool` で作成します(Android Studio 同梱の JDK や `flutter doctor -v` の「Java binary at」に表示される JDK の `keytool` を使えます)。

```sh
keytool -genkey -v \
  -keystore ~/upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias upload
```

- 実行するとパスワードと氏名などを聞かれます。
- 鍵ファイルはリポジトリの外(例ではホームディレクトリ)に置いてください。
- 現在の keytool の既定形式(PKCS12)では、キーストアのパスワードと鍵のパスワードは同じ値になります。

### 2. `android/key.properties` を作る

```properties
storePassword=<キーストアのパスワード>
keyPassword=<鍵のパスワード>
keyAlias=upload
storeFile=/Users/<ユーザー名>/upload-keystore.jks
```

- `storeFile` は絶対パスを推奨します(相対パスの場合は `android/app` からの相対になります)。
- `key.properties`・`*.jks`・`*.keystore` は `.gitignore` に入っています。**コミットしないでください。**
- 4つの項目のいずれかが欠けていると、ビルドはエラーで止まります。

### 3. ビルドして署名を確認する

```sh
flutter build appbundle --release   # Google Play 提出用(.aab)
flutter build apk --release         # 直接配布・確認用(.apk)
```

APK の署名は Android SDK の `apksigner` で確認できます。

```sh
~/Library/Android/sdk/build-tools/<バージョン>/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/app-release.apk
```

`Signer #1 certificate DN` に、手順1で入力した氏名などが表示されれば正しく署名されています。

### `key.properties` が無い場合

ローカルで動作確認できるよう、release ビルドは **debug 鍵** で署名されます(`apksigner` の表示は `CN=Android Debug`)。debug 鍵で署名したアプリはストアに提出できません。

このとき Gradle は「警告: android/key.properties がないため、release ビルドを debug 鍵で署名しています」と出力します。`flutter build` の通常の出力には表示されないため、確認するときは `flutter build apk --release -v` で実行してください。

## iOS

Xcode の自動署名(Automatically manage signing)で署名します。

1. Apple Developer Program に登録した Apple ID を、Xcode の Settings > Accounts に追加する。
2. `ios/Runner.xcworkspace` を Xcode で開き、Runner ターゲットの Signing & Capabilities で次を設定する。
   - **Team**: 自分の開発チームを選ぶ(現在は未設定)。
   - **Bundle Identifier**: 現在は `com.example.onePhotoDiary`。`com.example` で始まる ID は App Store に登録できないため、提出前に自分が管理する ID(例: `com.<自分のドメイン>.onePhotoDiary`)に変更し、App Store Connect にも同じ ID でアプリを登録する。
3. `flutter build ipa --release` でビルドし、Xcode の Organizer または Transporter でアップロードする。

> アプリID(Android の `com.example.one_photo_diary`、iOS の Bundle ID)は、公開後に変えると別のアプリ扱いになります。ストアに公開する前に決めてください。
