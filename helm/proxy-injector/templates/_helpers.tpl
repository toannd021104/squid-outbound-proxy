{{- define "proxy-injector.proxyEnvs" -}}
- name: HTTP_PROXY
  value: {{ .Values.proxy.httpProxy | quote }}
- name: HTTPS_PROXY
  value: {{ .Values.proxy.httpsProxy | quote }}
- name: NO_PROXY
  value: {{ .Values.proxy.noProxy | quote }}
- name: http_proxy
  value: {{ .Values.proxy.httpProxy | quote }}
- name: https_proxy
  value: {{ .Values.proxy.httpsProxy | quote }}
- name: no_proxy
  value: {{ .Values.proxy.noProxy | quote }}
{{- end }}
