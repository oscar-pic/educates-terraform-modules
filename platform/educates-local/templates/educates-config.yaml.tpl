clusterInfrastructure:
  provider: custom
clusterPackages:
  contour:
    enabled: true
    settings:
      infraProvider: kind
      externaldns:
        domains:
          - ${wildcard_domain}
      configFileContents:
        defaultHttpVersions:
          - "HTTP/1.1"
      contour:
        replicas: 1
      service:
        type: ClusterIP
        useHostPorts: true
  cert-manager:
    enabled: true
    settings: {}
  external-dns:
    enabled: true
    settings:
      infraProvider: custom
      deployment:
        args:
          - --source=ingress
          - --provider=google
          - --google-project=${gcp_project}
          - --domain-filter=${dns_zone}
          - --policy=upsert-only
          - --txt-owner-id=educates
  certs:
    enabled: true
    settings:
      domains: 
        - ${wildcard_domain}
      certProvider: acme-gcp
      acme:
        gcp:
          project: ${gcp_project}
  kyverno:
    enabled: true
    settings: {}
  educates:
    enabled: true
    settings:
      clusterSecurity:
        policyEngine: kyverno
      clusterIngress:
        domain: ${wildcard_domain}
        tlsCertificateRef:
          namespace: projectcontour
          name: educateswildcard        
      lookupService:
        enabled: true
