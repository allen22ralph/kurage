import 'jellyfin_api.dart';

/// The server as an administrator sees it (`GET /System/Info`).
class ServerInfo {
  const ServerInfo({
    required this.name,
    required this.version,
    required this.os,
    this.pendingRestart = false,
    this.updateAvailable = false,
  });

  factory ServerInfo.fromJson(Map<String, dynamic> json) => ServerInfo(
        name: json['ServerName'] as String? ?? 'Jellyfin',
        version: json['Version'] as String? ?? '',
        os: _os(json),
        pendingRestart: json['HasPendingRestart'] as bool? ?? false,
        updateAvailable: json['HasUpdateAvailable'] as bool? ?? false,
      );

  /// "Linux · X64"; empty when the server doesn't say (10.11 no longer
  /// names its OS, and the architecture alone says little).
  static String _os(Map<String, dynamic> json) {
    final name = json['OperatingSystemDisplayName'] ?? json['OperatingSystem'];
    if (name is! String || name.isEmpty) return '';
    final arch = json['SystemArchitecture'];
    return arch is String && arch.isNotEmpty ? '$name · $arch' : name;
  }

  final String name;
  final String version;
  final String os;
  final bool pendingRestart;
  final bool updateAvailable;
}

/// One of the server's scheduled tasks (`GET /ScheduledTasks`).
class ScheduledTask {
  const ScheduledTask({
    required this.id,
    required this.key,
    required this.name,
    required this.category,
    this.description = '',
    this.running = false,
    this.progress,
    this.lastEnded,
    this.lastStatus,
  });

  factory ScheduledTask.fromJson(Map<String, dynamic> json) {
    final last = json['LastExecutionResult'] as Map<String, dynamic>?;
    final state = json['State'] as String? ?? 'Idle';
    return ScheduledTask(
      id: json['Id'] as String,
      key: json['Key'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      category: json['Category'] as String? ?? 'Other',
      description: json['Description'] as String? ?? '',
      running: state != 'Idle',
      progress: (json['CurrentProgressPercentage'] as num?)?.toDouble(),
      lastEnded: DateTime.tryParse(last?['EndTimeUtc'] as String? ?? '')?.toLocal(),
      lastStatus: last?['Status'] as String?,
    );
  }

  final String id;

  /// Stable name of the task, e.g. "RefreshLibrary" for the library scan.
  final String key;
  final String name;
  final String category;
  final String description;
  final bool running;

  /// 0–100 while running, when the server says.
  final double? progress;
  final DateTime? lastEnded;

  /// "Completed", "Failed", "Cancelled", "Aborted".
  final String? lastStatus;

  bool get lastFailed => lastStatus == 'Failed' || lastStatus == 'Aborted';
}

/// A user as an administrator manages them (`GET /Users`), with the parts of
/// their policy the app offers.
class AdminUser {
  const AdminUser({
    required this.id,
    required this.name,
    required this.policy,
    this.hasPassword = true,
    this.lastActivity,
    this.primaryImageTag,
  });

  factory AdminUser.fromJson(Map<String, dynamic> json) => AdminUser(
        id: json['Id'] as String,
        name: json['Name'] as String? ?? '',
        hasPassword: json['HasPassword'] as bool? ?? true,
        lastActivity: DateTime.tryParse(json['LastActivityDate'] as String? ?? '')?.toLocal(),
        primaryImageTag: json['PrimaryImageTag'] as String?,
        policy: UserPolicy(json['Policy'] as Map<String, dynamic>? ?? const {}),
      );

  final String id;
  final String name;
  final bool hasPassword;
  final DateTime? lastActivity;
  final String? primaryImageTag;
  final UserPolicy policy;
}

/// Who may do what in watch together.
enum SyncPlayAccess {
  createAndJoin('CreateAndJoinGroups', 'Create and join groups'),
  join('JoinGroups', 'Join groups only'),
  none('None', 'No watch together');

  const SyncPlayAccess(this.apiName, this.label);

  final String apiName;
  final String label;

  static SyncPlayAccess parse(String? name) =>
      values.firstWhere((a) => a.apiName == name, orElse: () => SyncPlayAccess.createAndJoin);
}

/// A user's policy. Kept whole ([json]): the server replaces the policy on
/// save, so fields the app doesn't show are sent back unchanged.
class UserPolicy {
  const UserPolicy(this.json);

  final Map<String, dynamic> json;

  bool _flag(String key, {bool fallback = false}) => json[key] as bool? ?? fallback;

  bool get isAdministrator => _flag('IsAdministrator');
  bool get isDisabled => _flag('IsDisabled');
  bool get downloads => _flag('EnableContentDownloading', fallback: true);
  bool get transcoding => _flag('EnableVideoPlaybackTranscoding', fallback: true);
  bool get remuxing => _flag('EnablePlaybackRemuxing', fallback: true);
  bool get remoteAccess => _flag('EnableRemoteAccess', fallback: true);
  bool get allLibraries => _flag('EnableAllFolders', fallback: true);
  List<String> get libraries => [for (final id in json['EnabledFolders'] as List? ?? const []) '$id'];
  SyncPlayAccess get syncPlay => SyncPlayAccess.parse(json['SyncPlayAccess'] as String?);

  /// The highest parental rating value allowed; null for no limit.
  int? get maxParentalRating => (json['MaxParentalRating'] as num?)?.toInt();

  UserPolicy copyWith({
    bool? isAdministrator,
    bool? isDisabled,
    bool? downloads,
    bool? transcoding,
    bool? remuxing,
    bool? remoteAccess,
    bool? allLibraries,
    List<String>? libraries,
    SyncPlayAccess? syncPlay,
    int? Function()? maxParentalRating,
  }) =>
      UserPolicy({
        ...json,
        'IsAdministrator': ?isAdministrator,
        'IsDisabled': ?isDisabled,
        'EnableContentDownloading': ?downloads,
        // Video and audio transcoding go together in the app.
        if (transcoding != null) ...{
          'EnableVideoPlaybackTranscoding': transcoding,
          'EnableAudioPlaybackTranscoding': transcoding,
        },
        'EnablePlaybackRemuxing': ?remuxing,
        'EnableRemoteAccess': ?remoteAccess,
        'EnableAllFolders': ?allLibraries,
        'EnabledFolders': ?libraries,
        'SyncPlayAccess': ?syncPlay?.apiName,
        if (maxParentalRating != null) 'MaxParentalRating': maxParentalRating(),
      });
}

/// A device signed in to the server (`GET /Devices`).
class ServerDevice {
  const ServerDevice({
    required this.id,
    required this.name,
    required this.app,
    this.userName,
    this.lastActive,
  });

  factory ServerDevice.fromJson(Map<String, dynamic> json) => ServerDevice(
        id: json['Id'] as String,
        name: json['Name'] as String? ?? '',
        app: [json['AppName'], json['AppVersion']].whereType<String>().join(' '),
        userName: json['LastUserName'] as String?,
        lastActive: DateTime.tryParse(json['DateLastActivity'] as String? ?? '')?.toLocal(),
      );

  final String id;
  final String name;
  final String app;
  final String? userName;
  final DateTime? lastActive;
}

/// How much a metadata refresh redoes.
enum RefreshMode {
  scan('Scan for new and updated files', 'Default'),
  missing('Search for missing metadata', 'FullRefresh'),
  replaceAll('Replace all metadata', 'FullRefresh');

  const RefreshMode(this.label, this.apiMode);

  final String label;
  final String apiMode;
}

/// Server administration (administrator accounts only; others get 403).
class AdminApi {
  AdminApi(this._api);

  final JellyfinApi _api;

  Future<ServerInfo> serverInfo() async => ServerInfo.fromJson(await _api.getJson('/System/Info'));

  /// Scans every library for new, changed and removed files.
  Future<void> scanAllLibraries() => _api.postJson('/Library/Refresh');

  Future<List<ScheduledTask>> scheduledTasks() async => [
        for (final t in await _api.getList('/ScheduledTasks', query: {'isHidden': false}))
          ScheduledTask.fromJson(t as Map<String, dynamic>),
      ];

  Future<void> startTask(String id) => _api.postJson('/ScheduledTasks/Running/$id');

  Future<void> stopTask(String id) => _api.delete('/ScheduledTasks/Running/$id');

  Future<void> restart() => _api.postJson('/System/Restart');

  Future<void> shutdown() => _api.postJson('/System/Shutdown');

  /// Refreshes an item (a library, show, season, episode, movie…).
  Future<void> refreshItem(String itemId, {RefreshMode mode = RefreshMode.missing, bool replaceImages = false}) =>
      _api.postJson('/Items/$itemId/Refresh', query: {
        'metadataRefreshMode': mode.apiMode,
        'imageRefreshMode': mode == RefreshMode.scan ? 'Default' : 'FullRefresh',
        'replaceAllMetadata': mode == RefreshMode.replaceAll,
        'replaceAllImages': replaceImages,
        'regenerateTrickplay': false,
      });

  Future<List<AdminUser>> users() async => [
        for (final u in await _api.getList('/Users')) AdminUser.fromJson(u as Map<String, dynamic>),
      ];

  Future<AdminUser> createUser(String name, String password) async =>
      AdminUser.fromJson(await _api.postJson('/Users/New', body: {'Name': name, 'Password': password}));

  /// Renames [user]: the server takes the whole user back, renamed.
  Future<void> renameUser(String userId, String name) async {
    final user = await _api.getJson('/Users/$userId');
    await _api.postJson('/Users', query: {'userId': userId}, body: {...user, 'Name': name});
  }

  /// Sets [userId]'s password (an administrator needn't know the old one);
  /// an empty one leaves the account without a password.
  Future<void> setPassword(String userId, String password) => _api.postJson(
        '/Users/Password',
        query: {'userId': userId},
        body: password.isEmpty ? {'ResetPassword': true} : {'NewPw': password, 'CurrentPw': ''},
      );

  Future<void> deleteUser(String userId) => _api.delete('/Users/$userId');

  Future<void> savePolicy(String userId, UserPolicy policy) =>
      _api.postJson('/Users/$userId/Policy', body: policy.json);

  /// The server's libraries, for library access: (id, name).
  Future<List<({String id, String name})>> libraries() async {
    final data = await _api.getJson('/Library/MediaFolders');
    return [
      for (final f in data['Items'] as List? ?? const [])
        (id: (f as Map)['Id'] as String, name: f['Name'] as String? ?? ''),
    ];
  }

  /// Parental ratings the server knows, lowest first: (name, value).
  Future<List<({String name, int value})>> parentalRatings() async {
    final seen = <int>{};
    final ratings = [
      for (final r in await _api.getList('/Localization/ParentalRatings'))
        // 10.11 moved the number into RatingScore.
        if (((r as Map)['Value'] ?? (r['RatingScore'] as Map?)?['score']) case final num v when seen.add(v.toInt()))
          (name: r['Name'] as String? ?? '$v', value: v.toInt()),
    ]..sort((a, b) => a.value.compareTo(b.value));
    return ratings;
  }

  Future<List<ServerDevice>> devices({String? userId}) async {
    final data = await _api.getJson('/Devices', query: {'userId': userId});
    return [for (final d in data['Items'] as List? ?? const []) ServerDevice.fromJson(d as Map<String, dynamic>)];
  }

  /// Signs the device out (its sessions end; it has to sign in again).
  Future<void> signOutDevice(String deviceId) => _api.delete('/Devices', query: {'id': deviceId});
}
