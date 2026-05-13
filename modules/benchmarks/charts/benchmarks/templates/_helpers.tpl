{{- define "benchmarks.fullname" -}}
{{ .Values.global.name }}
{{- end }}

{{- define "benchmarks.namespace" -}}
{{ .Values.global.namespace }}
{{- end }}

{{- define "benchmarks.labels" -}}
app.kubernetes.io/name: {{ include "benchmarks.fullname" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: rhoai-platform-ops
{{- end }}

{{- define "benchmarks.selectorLabels" -}}
app.kubernetes.io/name: {{ include "benchmarks.fullname" . }}
{{- end }}

{{/*
Build --backend-kwargs JSON: configurable SSL verify (default false for
self-signed OpenShift route certs), add api_key when auth is configured.
*/}}
{{- define "benchmarks.backendKwargs" -}}
{{- if or .Values.benchmark.authToken .Values.benchmark.authSecret -}}
{"verify": {{ .Values.benchmark.verifySSL }}, "api_key": "$(AUTH_TOKEN)"}
{{- else -}}
{"verify": {{ .Values.benchmark.verifySSL }}}
{{- end -}}
{{- end }}
