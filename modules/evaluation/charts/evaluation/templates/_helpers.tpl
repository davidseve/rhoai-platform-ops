{{- define "evaluation.namespace" -}}
{{- .Values.global.namespace -}}
{{- end -}}

{{- define "evaluation.labels" -}}
app.kubernetes.io/name: {{ .Values.global.name }}
app.kubernetes.io/managed-by: Helm
app.kubernetes.io/part-of: rhoai-platform-ops
{{- end -}}
