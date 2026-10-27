import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名：读 android/key.properties（本地，已 gitignore）；CI 由工作流按 secrets 生成。
// 没有该文件时回退 debug 签名，保证 `flutter run --release` 仍可用。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "com.dsh.musicorganizer.musicorganizer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.dsh.musicorganizer.musicorganizer"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // 有正式 keystore 就用它（本地与 CI 签名一致，升级才能覆盖安装）。
            //
            // 缺 keystore 时**直接构建失败**，不再静默回退 debug 签名：签名一换，
            // 装到已装正式版的设备上会让系统清掉所有 SAF 目录授权，表现为
            // 「升级一次就丢一次曲库目录」，比构建失败难查得多。
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else if (project.hasProperty("allowDebugSign")) {
                // 显式开的后门：本地临时调试用。产出的包签名与正式版不同，
                // 覆盖安装会丢失已授权的曲库目录。
                logger.warn(
                    "SIGNATURE: 正在用 debug 签名打 release 包 —— 与正式版签名不一致，"
                        + "覆盖安装会丢失已授权的曲库目录"
                )
                signingConfigs.getByName("debug")
            } else {
                throw GradleException(
                    "缺少 android/key.properties：release 包必须使用正式签名。"
                        + "签名不一致会让已装正式版的设备丢失曲库目录授权。"
                        + "确实只是本地调试，请加 -PallowDebugSign=true"
                )
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
