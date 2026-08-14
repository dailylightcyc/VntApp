class NetworkConfig {
  String itemKey;
  String configName;
  String token;
  String deviceName;
  String virtualIPv4;
  String serverAddress;
  List<String> stunServers;
  List<String> inIps;
  List<String> outIps;
  List<String> portMappings;
  String groupPassword;
  bool isServerEncrypted;
  String protocol;
  bool dataFingerprintVerification;
  String encryptionAlgorithm;
  String deviceID;
  String virtualNetworkCardName;
  int mtu;
  List<int> ports;
  bool firstLatency;
  bool noInIpProxy;
  List<String> dns;
  double simulatedPacketLossRate;
  int simulatedLatency;
  String punchModel;
  String useChannelType;
  String compressor;
  bool allowWg;
  String localDev;
  bool disableRelay;
  String hook;

  NetworkConfig({
    required this.itemKey,
    required this.configName,
    required this.token,
    required this.deviceName,
    required this.virtualIPv4,
    required this.serverAddress,
    required this.stunServers,
    required this.inIps,
    required this.outIps,
    required this.portMappings,
    required this.groupPassword,
    required this.isServerEncrypted,
    required this.protocol,
    required this.dataFingerprintVerification,
    required this.encryptionAlgorithm,
    required this.deviceID,
    required this.virtualNetworkCardName,
    required this.mtu,
    required this.ports,
    required this.firstLatency,
    required this.noInIpProxy,
    required this.dns,
    required this.simulatedPacketLossRate,
    required this.simulatedLatency,
    required this.punchModel,
    required this.useChannelType,
    required this.compressor,
    required this.allowWg,
    required this.localDev,
    required this.disableRelay,
    required this.hook,
  });

  NetworkConfig copyWith({String? serverAddress, String? protocol}) {
    return NetworkConfig(
      itemKey: itemKey,
      configName: configName,
      token: token,
      deviceName: deviceName,
      virtualIPv4: virtualIPv4,
      serverAddress: serverAddress ?? this.serverAddress,
      stunServers: List<String>.from(stunServers),
      inIps: List<String>.from(inIps),
      outIps: List<String>.from(outIps),
      portMappings: List<String>.from(portMappings),
      groupPassword: groupPassword,
      isServerEncrypted: isServerEncrypted,
      protocol: protocol ?? this.protocol,
      dataFingerprintVerification: dataFingerprintVerification,
      encryptionAlgorithm: encryptionAlgorithm,
      deviceID: deviceID,
      virtualNetworkCardName: virtualNetworkCardName,
      mtu: mtu,
      ports: List<int>.from(ports),
      firstLatency: firstLatency,
      noInIpProxy: noInIpProxy,
      dns: List<String>.from(dns),
      simulatedPacketLossRate: simulatedPacketLossRate,
      simulatedLatency: simulatedLatency,
      punchModel: punchModel,
      useChannelType: useChannelType,
      compressor: compressor,
      allowWg: allowWg,
      localDev: localDev,
      disableRelay: disableRelay,
      hook: hook,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'itemKey': itemKey,
      'config_name': configName,
      'token': token,
      'name': deviceName,
      'ip': virtualIPv4,
      'server_address': serverAddress,
      'stun_server': stunServers,
      'in_ips': inIps,
      'out_ips': outIps,
      'mapping': portMappings,
      'password': groupPassword,
      'server_encrypt': isServerEncrypted,
      'protocol': protocol,
      'finger': dataFingerprintVerification,
      'cipher_model': encryptionAlgorithm,
      'device_id': deviceID,
      'device_name': virtualNetworkCardName,
      'mtu': mtu,
      'ports': ports,
      'first_latency': firstLatency,
      'no_proxy': noInIpProxy,
      'dns': dns,
      'packet_loss': simulatedPacketLossRate,
      'packet_delay': simulatedLatency,
      'punch_model': punchModel,
      'use_channel': useChannelType,
      'compressor': compressor,
      'allow_wire_guard': allowWg,
      'local_dev': localDev,
      'disable_relay': disableRelay,
      'hook': hook,
    };
  }

  Map<String, dynamic> toJsonSimple() {
    return {
      if (configName.isNotEmpty) 'config_name': configName,
      if (token.isNotEmpty) 'token': token,
      if (deviceName.isNotEmpty) 'name': deviceName,
      if (virtualIPv4.isNotEmpty) 'ip': virtualIPv4,
      if (serverAddress.isNotEmpty) 'server_address': serverAddress,
      if (stunServers.isNotEmpty) 'stun_server': stunServers,
      if (inIps.isNotEmpty) 'in_ips': inIps,
      if (outIps.isNotEmpty) 'out_ips': outIps,
      if (portMappings.isNotEmpty) 'mapping': portMappings,
      if (groupPassword.isNotEmpty) 'password': groupPassword,
      if (isServerEncrypted) 'server_encrypt': isServerEncrypted,
      if (protocol.isNotEmpty) 'protocol': protocol,
      if (dataFingerprintVerification) 'finger': dataFingerprintVerification,
      if (encryptionAlgorithm.isNotEmpty) 'cipher_model': encryptionAlgorithm,
      if (deviceID.isNotEmpty) 'device_id': deviceID,
      if (virtualNetworkCardName.isNotEmpty)
        'device_name': virtualNetworkCardName,
      if (mtu != 0) 'mtu': mtu,
      if (ports.isNotEmpty) 'ports': ports,
      if (firstLatency) 'first_latency': firstLatency,
      if (noInIpProxy) 'no_proxy': noInIpProxy,
      if (dns.isNotEmpty) 'dns': dns,
      if (simulatedPacketLossRate != 0) 'packet_loss': simulatedPacketLossRate,
      if (simulatedLatency != 0) 'packet_delay': simulatedLatency,
      if (punchModel.isNotEmpty) 'punch_model': punchModel,
      if (useChannelType.isNotEmpty) 'use_channel': useChannelType,
      if (compressor.isNotEmpty) 'compressor': compressor,
      if (allowWg) 'allow_wire_guard': allowWg,
      if (localDev.isNotEmpty) 'local_dev': localDev,
      if (disableRelay) 'disable_relay': disableRelay,
      if (hook.isNotEmpty) 'hook': hook,
    };
  }

  factory NetworkConfig.fromJson(Map<String, dynamic> json) {
    final storedAddress = (json['server_address'] as String).trim();
    final lowerAddress = storedAddress.toLowerCase();
    final migrateDefaultServerToUdp =
        lowerAddress == 'tcp://47.108.138.177:29872' ||
        lowerAddress == 'tcp://vnt.wherewego.top:29872';
    return NetworkConfig(
      itemKey: json['itemKey'],
      configName: json['config_name'],
      token: json['token'],
      deviceName: json['name'],
      virtualIPv4: json['ip'],
      serverAddress: migrateDefaultServerToUdp
          ? storedAddress.substring('tcp://'.length)
          : storedAddress,
      stunServers: List<String>.from(json['stun_server']),
      inIps: List<String>.from(json['in_ips']),
      outIps: List<String>.from(json['out_ips']),
      portMappings: List<String>.from(json['mapping']),
      groupPassword: json['password'],
      isServerEncrypted: json['server_encrypt'],
      protocol: migrateDefaultServerToUdp ? 'UDP' : json['protocol'] ?? 'UDP',
      dataFingerprintVerification: json['finger'],
      encryptionAlgorithm: json['cipher_model'],
      deviceID: json['device_id'],
      virtualNetworkCardName: json['device_name'],
      mtu: json['mtu'],
      ports: List<int>.from(json['ports']),
      firstLatency: json['first_latency'],
      noInIpProxy: json['no_proxy'],
      dns: List<String>.from(json['dns']),
      simulatedPacketLossRate: json['packet_loss'],
      simulatedLatency: json['packet_delay'],
      punchModel: json['punch_model'],
      useChannelType: json['use_channel'],
      compressor: json['compressor'] ?? 'none',
      allowWg: json['allow_wire_guard'] ?? false,
      localDev: json['local_dev'] ?? '',
      disableRelay: json['disable_relay'] ?? false,
      hook: json['hook'] ?? '',
    );
  }
}
