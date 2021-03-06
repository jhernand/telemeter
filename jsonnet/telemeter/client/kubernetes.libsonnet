local k = import 'ksonnet/ksonnet.beta.3/k.libsonnet';
local secretName = 'telemeter-client';
local secretVolumeName = 'secret-telemeter-client';
local secretMountPath = '/etc/telemeter';
local matchFileName = 'match-rules';
local tlsSecret = 'telemeter-client-tls';
local tlsVolumeName = 'telemeter-client-tls';
local tlsMountPath = '/etc/tls/private';
local servingCertsCABundle = 'serving-certs-ca-bundle';
local servingCertsCABundleFileName = 'service-ca.crt';
local servingCertsCABundleMountPath = '/etc/%s' % servingCertsCABundle;
local fromTokenFile = '/var/run/secrets/kubernetes.io/serviceaccount/token';
local metricsPort = 8080;
local securePort = 8443;

{
  _config+:: {
    namespace: 'openshift-monitoring',

    telemeterClient+:: {
      anonymizeLabels: [],
      from: 'https://prometheus-k8s.%(namespace)s.svc:9091' % $._config,
      matchRules: [],
      salt: '',
      serverName: 'server-name-replaced-at-runtime',
      to: 'https://infogw.api.openshift.com',
      token: '',
    },

    versions+:: {
      // TODO(squat): change this to v4.0 once that image is built
      configmapReload: 'v3.11',
      kubeRbacProxy: 'v0.3.1',
      telemeterClient: 'v4.0',
    },

    imageRepos+:: {
      configmapReload: 'quay.io/openshift/origin-configmap-reload',
      kubeRbacProxy: 'quay.io/coreos/kube-rbac-proxy',
      telemeterClient: 'quay.io/openshift/origin-telemeter',
    },
  },

  telemeterClient+:: {
    clusterRoleBinding:
      local clusterRoleBinding = k.rbac.v1.clusterRoleBinding;

      clusterRoleBinding.new() +
      clusterRoleBinding.mixin.metadata.withName('telemeter-client') +
      clusterRoleBinding.mixin.roleRef.withApiGroup('rbac.authorization.k8s.io') +
      clusterRoleBinding.mixin.roleRef.withName('telemeter-client') +
      clusterRoleBinding.mixin.roleRef.mixinInstance({ kind: 'ClusterRole' }) +
      clusterRoleBinding.withSubjects([{ kind: 'ServiceAccount', name: 'telemeter-client', namespace: $._config.namespace }]),

    clusterRole:
      local clusterRole = k.rbac.v1.clusterRole;
      local policyRule = clusterRole.rulesType;

      local authenticationRule = policyRule.new() +
                                 policyRule.withApiGroups(['authentication.k8s.io']) +
                                 policyRule.withResources([
                                   'tokenreviews',
                                 ]) +
                                 policyRule.withVerbs(['create']);

      local authorizationRule = policyRule.new() +
                                policyRule.withApiGroups(['authorization.k8s.io']) +
                                policyRule.withResources([
                                  'subjectaccessreviews',
                                ]) +
                                policyRule.withVerbs(['create']);

      clusterRole.new() +
      clusterRole.mixin.metadata.withName('telemeter-client') +
      clusterRole.withRules([authenticationRule, authorizationRule]),

    clusterRoleBindingView:
      local clusterRoleBinding = k.rbac.v1.clusterRoleBinding;

      clusterRoleBinding.new() +
      clusterRoleBinding.mixin.metadata.withName('telemeter-client-view') +
      clusterRoleBinding.mixin.roleRef.withApiGroup('rbac.authorization.k8s.io') +
      clusterRoleBinding.mixin.roleRef.withName('cluster-monitoring-view') +
      clusterRoleBinding.mixin.roleRef.mixinInstance({ kind: 'ClusterRole' }) +
      clusterRoleBinding.withSubjects([{ kind: 'ServiceAccount', name: 'telemeter-client', namespace: $._config.namespace }]),

    deployment:
      local deployment = k.apps.v1beta2.deployment;
      local container = k.apps.v1beta2.deployment.mixin.spec.template.spec.containersType;
      local volume = k.apps.v1beta2.deployment.mixin.spec.template.spec.volumesType;
      local containerPort = container.portsType;
      local containerVolumeMount = container.volumeMountsType;
      local containerEnv = container.envType;

      local podLabels = { 'k8s-app': 'telemeter-client' };
      local secretMount = containerVolumeMount.new(secretVolumeName, secretMountPath);
      local secretVolume = volume.fromSecret(secretVolumeName, secretName);
      local tlsMount = containerVolumeMount.new(tlsVolumeName, tlsMountPath);
      local tlsVolume = volume.fromSecret(tlsVolumeName, tlsSecret);
      local sccabMount = containerVolumeMount.new(servingCertsCABundle, servingCertsCABundleMountPath);
      local sccabVolume = volume.withName(servingCertsCABundle) + volume.mixin.configMap.withName('telemeter-client-serving-certs-ca-bundle');
      local anonymize = containerEnv.fromSecretRef('ANONYMIZE_LABELS', secretName, 'anonymizeLabels');
      local id = containerEnv.fromSecretRef('ID', secretName, 'id');
      local to = containerEnv.fromSecretRef('TO', secretName, 'to');

      local telemeterClient =
        container.new('telemeter-client', $._config.imageRepos.telemeterClient + ':' + $._config.versions.telemeterClient) +
        container.withCommand([
          '/usr/bin/telemeter-client',
          '--id=$(ID)',
          '--from=' + $._config.telemeterClient.from,
          '--from-ca-file=%s/%s' % [servingCertsCABundleMountPath, servingCertsCABundleFileName],
          '--from-token-file=' + fromTokenFile,
          '--to=$(TO)',
          '--to-token-file=%s/token' % secretMountPath,
          '--listen=localhost:' + metricsPort,
          '--match-file=%s/%s' % [secretMountPath, matchFileName],
          '--anonymize-salt-file=%s/salt' % secretMountPath,
          '--anonymize-labels=$(ANONYMIZE_LABELS)',
        ]) +
        container.withPorts(containerPort.newNamed('http', metricsPort)) +
        container.withVolumeMounts([sccabMount, secretMount]) +
        container.withEnv([anonymize, id, to]);

      local reload =
        container.new('reload', $._config.imageRepos.configmapReload + ':' + $._config.versions.configmapReload) +
        container.withArgs([
          '--webhook-url=http://localhost:9000/-/reload',
          '--volume-dir=' + servingCertsCABundleMountPath,
        ]) +
        container.withVolumeMounts([sccabMount]);

      local proxy =
        container.new('kube-rbac-proxy', $._config.imageRepos.kubeRbacProxy + ':' + $._config.versions.kubeRbacProxy) +
        container.withArgs([
          '--secure-listen-address=:' + securePort,
          '--upstream=http://127.0.0.1:%s/' % metricsPort,
          '--tls-cert-file=%s/tls.crt' % tlsMountPath,
          '--tls-private-key-file=%s/tls.key' % tlsMountPath,
        ] + if std.objectHas($._config, 'tlsCipherSuites') then [
          '--tls-cipher-suites=' + std.join(',', $._config.tlsCipherSuites),
        ] else []) +
        container.withPorts(containerPort.new(securePort) + containerPort.withName('https')) +
        container.mixin.resources.withRequests({ cpu: '10m', memory: '20Mi' }) +
        container.mixin.resources.withLimits({ cpu: '20m', memory: '40Mi' }) +
        container.withVolumeMounts([tlsMount]);


      deployment.new('telemeter-client', 1, [telemeterClient, reload, proxy], podLabels) +
      deployment.mixin.metadata.withNamespace($._config.namespace) +
      deployment.mixin.metadata.withLabels(podLabels) +
      deployment.mixin.spec.selector.withMatchLabels(podLabels) +
      deployment.mixin.spec.template.spec.withServiceAccountName('telemeter-client') +
      deployment.mixin.spec.template.spec.withVolumes([sccabVolume, secretVolume, tlsVolume]),

    secret:
      local secret = k.core.v1.secret;

      secret.new(secretName, {
        [matchFileName]: std.base64(std.join('\n', $._config.telemeterClient.matchRules)),
        anonymizeLabels: std.base64(std.join(',', $._config.telemeterClient.anonymizeLabels)),
        salt: std.base64($._config.telemeterClient.salt),
        to: std.base64($._config.telemeterClient.to),
        token: std.base64($._config.telemeterClient.token),
      }) +
      secret.mixin.metadata.withNamespace($._config.namespace) +
      secret.mixin.metadata.withLabels({ 'k8s-app': 'telemeter-client' }),

    service:
      local service = k.core.v1.service;
      local servicePort = k.core.v1.service.mixin.spec.portsType;

      local servicePortHTTPS = servicePort.newNamed('https', securePort, 'https');

      service.new('telemeter-client', $.telemeterClient.deployment.spec.selector.matchLabels, [servicePortHTTPS]) +
      service.mixin.metadata.withNamespace($._config.namespace) +
      service.mixin.metadata.withLabels({ 'k8s-app': 'telemeter-client' }) +
      service.mixin.spec.withClusterIp('None') +
      service.mixin.metadata.withAnnotations({
        'service.alpha.openshift.io/serving-cert-secret-name': tlsSecret,
      }),

    serviceAccount:
      local serviceAccount = k.core.v1.serviceAccount;

      serviceAccount.new('telemeter-client') +
      serviceAccount.mixin.metadata.withNamespace($._config.namespace),

    serviceMonitor:
      {
        apiVersion: 'monitoring.coreos.com/v1',
        kind: 'ServiceMonitor',
        metadata: {
          name: 'telemeter-client',
          namespace: $._config.namespace,
          labels: {
            'k8s-app': 'telemeter-client',
          },
        },
        spec: {
          jobLabel: 'k8s-app',
          selector: {
            matchLabels: {
              'k8s-app': 'telemeter-client',
            },
          },
          endpoints: [
            {
              bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
              interval: '30s',
              port: 'https',
              scheme: 'https',
              tlsConfig: {
                caFile: '/etc/prometheus/configmaps/serving-certs-ca-bundle/%s' % servingCertsCABundleFileName,
                serverName: $._config.telemeterClient.serverName,
              },
            },
          ],
        },
      },

    servingCertsCABundle+:
      local configmap = k.core.v1.configMap;

      configmap.new('telemeter-client-serving-certs-ca-bundle', { [servingCertsCABundleFileName]: '' }) +
      configmap.mixin.metadata.withNamespace($._config.namespace) +
      configmap.mixin.metadata.withAnnotations({ 'service.alpha.openshift.io/inject-cabundle': 'true' }),
  },
}
