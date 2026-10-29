package delivery.pipeline.common.api.domain.common.file;

import delivery.pipeline.common.api.common.Constants;
import org.springframework.stereotype.Service;

import java.util.List;

/**
 * apDeliveryPipelineCommonApi
 * delivery.pipeline.common.api.file
 *
 * @author kimdojun
 * @version 1.0
 * @since 6 /13/2017
 */

@Service
public class FileService {

    private final FileInfoRepository fileInfoRepository;


    /**
     * Instantiates a new Job service.
     *
     * @param fileInfoRepository the file repository
     */
    public FileService(FileInfoRepository fileInfoRepository) {
        this.fileInfoRepository = fileInfoRepository;
    }

    /**
     * Create FileInfo.
     *
     * @param fileInfo the fileInfo
     * @return the fileInfo
     */
    FileInfo createFileInfo(FileInfo fileInfo) {
        return fileInfoRepository.save(fileInfo);
    }

    FileInfo getFileInfo(long id) {
        return fileInfoRepository.findById(id);
    }

    List<FileInfo> getFileInfoList() {
        return fileInfoRepository.findAll();
    }

    public String deleteFile(long id) {
        fileInfoRepository.delete(id);
        return Constants.RESULT_STATUS_SUCCESS;
    }
}
