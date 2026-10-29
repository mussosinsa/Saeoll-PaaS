package delivery.pipeline.common.api.domain.common.file;

import org.springframework.data.jpa.repository.JpaRepository;

import javax.transaction.Transactional;

/**
 * apDeliveryPipelineCommonApi
 * delivery.pipeline.common.api.file
 *
 * @author kimdojun
 * @version 1.0
 * @since 6 /13/2017
 */
@Transactional
public interface FileInfoRepository extends JpaRepository<FileInfo, Long> {

    FileInfo findById(long id);

}
