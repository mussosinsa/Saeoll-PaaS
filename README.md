## Related Repositories

<table>
<thead>
  <tr>
    <th>플랫폼</th>
    <th><a href="https://github.com/K-PaaS/cp-deployment">컨테이너 플랫폼</a></th>
    <th>&nbsp;&nbsp;&nbsp;<a href="https://github.com/K-PaaS/sidecar-deployment.git">사이드카</a>&nbsp;&nbsp;&nbsp;</th>
  </tr>
</thead>
<tbody>
  <tr>
    <td align="center">포털</td>
    <td align="center"><a href="https://github.com/K-PaaS/cp-portal-release">CP 포털</a></td>
    <td align="center">-</td>
  </tr>
  <tr>
    <td rowspan="8">Component <br>/서비스</td>
    <td align="center"><a href="https://github.com/K-PaaS/cp-portal-ui">Portal UI</a></td>
    <td align="center"><a href="https://github.com/K-PaaS/sidecar-portal-ui">Portal UI</a></td>
  </tr>
  <tr>
    <td align="center"><a href="https://github.com/K-PaaS/cp-portal-api">Portal API</a></td>
    <td align="center"><a href="https://github.com/K-PaaS/sidecar-portal-api">Portal API</a></td>
  </tr>
  <tr>
    <td align="center"><a href="https://github.com/K-PaaS/cp-portal-common-api">Common API</a></td>
    <td align="center"></td>
  </tr>
  <tr>
    <td align="center"><a href="https://github.com/K-PaaS/cp-metrics-api">Metric API</a></td>
    <td align="center"></td>
  </tr>
  <tr>
    <td align="center"><a href="https://github.com/K-PaaS/cp-terraman">Terraman API</a></td>
    <td align="center"></td>
  </tr>
  <tr>
    <td align="center"><a href="https://github.com/K-PaaS/cp-catalog-api">Catalog API</a></td>
    <td align="center"></td>
  </tr>
  <tr>
    <td align="center"><a href="https://github.com/K-PaaS/cp-chaos-api">Chaos API</a></td>
    <td align="center"></td>
  </tr>
  <tr>
    <td align="center"><a href="https://github.com/K-PaaS/cp-chaos-collector">Chaos Collector API</a></td>
    <td align="center"></td>
  </tr>
</tbody></table>
<i>🚩 You are here.</i>

## Notice
#### 릴리즈의 경로가 https://nextcloud.paas-ta.org/ 에서 https://nextcloud.k-paas.org/ 로 변경되었습니다

<br>

# K-PaaS 컨테이너 플랫폼 클러스터 DEPLOYMENT

## 소개
쿠버네티스 기반의 컨테이너 오케스트레이션 플랫폼의 단독형 배포, Edge 배포를 위한 설치에 필요한 파일을 제공하고 설치가이드는 아래 Link를 참조한다.

## 기본 클러스터 배포
- 클러스터 설치
  + [싱글 클러스터 설치 가이드](https://github.com/K-PaaS/container-platform/blob/master/install-guide/standalone/cp-cluster-install-single.md)
  + [멀티 클러스터 설치 가이드](https://github.com/K-PaaS/container-platform/blob/master/install-guide/standalone/cp-cluster-install-multi.md)
  + [설치 및 배포 파일](https://github.com/K-PaaS/cp-deployment/tree/master)

## Edge 배포
- Edge 설치
  + [Edge 설치 가이드](https://github.com/K-PaaS/container-platform/blob/master/install-guide/edge/cp-edge-install.md)
  + [설치 및 배포 파일](https://github.com/K-PaaS/cp-deployment/tree/master)

## 릴리즈
- https://github.com/K-PaaS/cp-portal-release

### 기존 Kubernetes에 CP-Portal 설치

`standalone/install-existing-k8s.sh`는 CP-Portal을 포함하여 설치하지만, CP-Portal
배포 파일은 이 저장소가 아닌 위의 `cp-portal-release` 저장소에서 별도로
제공됩니다. 릴리즈를 내려받은 뒤 manifest 경로를 명시하여 실행합니다.

```bash
CP_PORTAL_MANIFEST=/root/cp-portal-release/<manifest-path> \
  /root/Saeoll-PaaS/standalone/install-existing-k8s.sh
```

CP-Portal을 Helm chart로 패키징한 환경에서는 manifest 대신 실제 chart 참조와
필요한 values 파일을 지정할 수 있습니다.

```bash
CP_PORTAL_CHART=/path/to/cp-portal-chart \
CP_PORTAL_VALUES_FILE=/path/to/values.yaml \
  /root/Saeoll-PaaS/standalone/install-existing-k8s.sh
```

## 메인
- https://github.com/K-PaaS/container-platform

## 라이선스
[Apache-2.0 License](http://www.apache.org/licenses/LICENSE-2.0)를 사용한다.
