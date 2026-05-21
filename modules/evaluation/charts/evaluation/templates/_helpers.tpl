{{- define "evaluation.namespace" -}}
{{- .Values.global.namespace -}}
{{- end -}}

{{- define "evaluation.labels" -}}
app.kubernetes.io/name: {{ .Values.global.name }}
app.kubernetes.io/managed-by: Helm
app.kubernetes.io/part-of: rhoai-platform-ops
{{- end -}}

{{- define "evaluation.ca-bundle-name" -}}
{{- .Values.caBundle.name | default "combined-ca-bundle" -}}
{{- end -}}

{{- define "evaluation.benchmarks.backendKwargs" -}}
{{- if or .Values.benchmarks.benchmark.authToken .Values.benchmarks.benchmark.authSecret -}}
{"api_key": "$(AUTH_TOKEN)"}
{{- else -}}
{}
{{- end -}}
{{- end -}}
