# 发布签名配置

本应用的安装包**必须用固定的一把正式 keystore 签名**。原因不是安全洁癖，而是两个直接
影响用户的功能后果：

- 签名不一致时，Android 会把它当成另一个应用，覆盖安装会被拒绝；
- 即使装上了，系统也会清掉本应用已获得的目录访问授权（SAF），用户表现为
  **「升级一次，曲库目录就没了」**，必须重新授权。

所以：`android/app/build.gradle.kts` 在缺少签名配置时**直接让 release 构建失败**，
而不是悄悄改用调试签名。仓库里不含任何签名材料，`key.properties` 与 keystore 都在
`.gitignore` 中。

---

## 1. 本地构建

在 `android/key.properties` 写入（这个文件不入库）：

```properties
storeFile=<keystore 文件的绝对路径>
storePassword=<密钥库口令>
keyAlias=<别名>
keyPassword=<密钥口令>
```

然后照常构建即可：

```bash
flutter build apk --release --split-per-abi
```

只想在本机临时跑一个 release 包、不在意签名一致时，可以显式开后门：

```bash
flutter build apk --release -PallowDebugSign=true
```

> 用这个参数打出来的包签名与正式版不同，**不要发给别人**。

## 2. 换一台机器

**把原来的 keystore 文件整份复制过去**，再按上面格式写 `key.properties` 即可。
必须是同一把钥匙；重新生成一把等于换签名，后果见第 5 节。

## 3. 只有在新项目 / 钥匙确实丢了才重新生成

```bash
keytool -genkeypair -v \
  -keystore release.keystore \
  -alias musicorganizer \
  -keyalg RSA -keysize 2048 -validity 10000
```

按提示填好口令后，把生成的 `release.keystore` 放到 `android/app/` 下，并在
`android/key.properties` 里写 `storeFile=release.keystore`（相对路径即可）。

## 4. 持续集成（GitHub Actions）

`.github/workflows/release.yml` 需要 4 个 repository secret：

| Secret | 内容 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | keystore 文件的 base64（`base64 -w0 release.keystore`） |
| `ANDROID_STORE_PASSWORD` | 密钥库口令 |
| `ANDROID_KEY_PASSWORD` | 密钥口令 |
| `ANDROID_KEY_ALIAS` | 别名（缺省 `musicorganizer`） |

没配 `ANDROID_KEYSTORE_BASE64` 时，工作流会直接报 error 并停止，不会产出调试签名的包。

## 5. 换钥匙或丢钥匙的后果

| 情况 | 后果 |
|---|---|
| 换了 keystore | 所有已安装用户升级后都会被当成新装：要么装不上，要么装上了丢失曲库目录授权 |
| keystore 丢失 | 再也无法为已发布的版本出升级包，只能换包名或让用户卸载重装 |

**务必把 keystore 与 `key.properties` 一起离线备份**（私有网盘、加密 U 盘均可，
不要放进任何代码仓库，也不要放进会同步到公开位置的目录）。
