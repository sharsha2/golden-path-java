# kubectl troubleshooting cheat sheet

| Symptom (STATUS) | First command | Usual cause |
|---|---|---|
| ImagePullBackOff / ErrImagePull | describe pod -> Events | wrong image/tag, registry auth, private registry |
| CrashLoopBackOff | logs --previous | app crash, bad config, missing env, OOM |
| CreateContainerConfigError | describe pod -> Events | missing ConfigMap/Secret or key |
| Running but 0/1 Ready | describe pod -> readiness events | wrong probe path/port, app dependency down |
| Pending | describe pod -> Events | not enough CPU/memory, node selector, PVC not bound |
| OOMKilled (Last State) | describe pod | memory limit too low or JVM heap not container-aware |

Order: get -> describe (read Events) -> logs (--previous) -> get events -> exec (if shell exists)
Rollback: kubectl rollout undo deploy/<name>   History: kubectl rollout history deploy/<name>